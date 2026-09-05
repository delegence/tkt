#!/usr/bin/env bash
# Focused CLI tests. All ticket writes stay in a temporary directory.
set -euo pipefail
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/tkt
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tkt-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
unset TICKETS_DIR_PATH
mkdir -p "$TMP/project/.tickets"
cd "$TMP/project"

fail() { echo "FAIL: $*" >&2; exit 1; }
tkt() { "$SCRIPT" "$@"; }
expect_failure() {
    if "$@" > "$TMP/stdout" 2> "$TMP/stderr"; then
        fail "command should fail: $*"
    fi
    [[ -s "$TMP/stderr" ]] || fail "missing error message: $*"
}
fixture() {
    local id="$1" status="${2:-open}" deps="${3:-[]}"
    printf '%s\n' '---' "id: $id" "status: $status" "deps: $deps" 'links: []' \
        'type: task' 'priority: 2' '---' "# $id" > ".tickets/$id.md"
}
check_json() {
    tkt query | jq -se "$1" > /dev/null || fail "JSON assertion: $1"
}

# Parent discovery and explicit paths, including spaces.
fixture a
mkdir -p src/deep
(cd src/deep; tkt ls) | grep -q '^a ' || fail 'parent directory lookup'
[[ ! -e src/deep/.tickets ]] || fail 'nested tickets directory created'
TICKETS_DIR_PATH="$TMP/custom tickets" tkt create Custom > "$TMP/custom-id"
[[ -f "$TMP/custom tickets/$(< "$TMP/custom-id").md" ]] || fail 'environment override'
[[ $(tkt query | jq -s length) == 1 ]] || fail 'override changed project tickets'
echo 'PASS: directory selection'

# Lists use exact members, preserve ordering, and are idempotent.
fixture a-long
fixture b
fixture c
tkt link a b > /dev/null
tkt link a c > /dev/null
tkt link a b a > /dev/null
check_json 'map(select(.id == "a"))[0].links == ["b", "c"]'
check_json 'map(select(.id == "b"))[0].links == ["a"]'
tkt unlink a b > /dev/null
tkt unlink a b > /dev/null
check_json 'map(select(.id == "a"))[0].links == ["c"]'
check_json 'map(select(.id == "b"))[0].links == []'
tkt dep b a-long > /dev/null
tkt dep b a > /dev/null
tkt dep b c > /dev/null
tkt dep b a > /dev/null
check_json 'map(select(.id == "b"))[0].deps == ["a-long", "a", "c"]'
tkt undep b a > /dev/null
check_json 'map(select(.id == "b"))[0].deps == ["a-long", "c"]'
tkt undep b a-long > /dev/null
tkt undep b c > /dev/null
check_json 'map(select(.id == "b"))[0].deps == []'
expect_failure tkt dep a a
# Also insert a missing field without changing a same-named body field.
printf '%s\n' '---' 'id: missing-field' 'status: open' '---' '# Missing field' 'links: [example]' > .tickets/missing-field.md
tkt link missing-field a > /dev/null
check_json 'map(select(.id == "missing-field"))[0].links == ["a"]'
grep -qx 'links: \[example\]' .tickets/missing-field.md || fail 'body links changed'
echo 'PASS: dependency and link updates'

# Readers and writers stop at the end of the initial frontmatter block.
fixture body
printf '\nstatus: open\n---\nstatus: closed\nassignee: body example\n---\n' > "$TMP/body"
cat "$TMP/body" >> .tickets/body.md
check_json 'map(select(.id == "body"))[0].status == "open"'
tkt close body > /dev/null
tail -n 6 .tickets/body.md > "$TMP/body-after"
cmp "$TMP/body" "$TMP/body-after" || fail 'status update changed body'
tkt reopen body > /dev/null
tkt ls --ready | grep -q '^body ' || fail 'body metadata affected listing'
printf 'not frontmatter\nstatus: open\n' > .tickets/invalid.md
cp .tickets/invalid.md "$TMP/invalid-before"
expect_failure tkt close invalid
cmp .tickets/invalid.md "$TMP/invalid-before" || fail 'invalid file changed'
echo 'PASS: frontmatter boundaries and safe updates'

# JSON arrays and literal string escaping share the same metadata reader.
assignee=$'Team: "Ops" \\ files\tgroup'
ref=$'ref\\name\bvalue'
escaped=$(tkt create Escaping --assignee "$assignee" --external-ref "$ref" --tags 'ui, backend')
tkt query | jq -se --arg id "$escaped" --arg assignee "$assignee" --arg ref "$ref" \
    'map(select(.id == $id))[0] | .assignee == $assignee and .["external-ref"] == $ref and .tags == ["ui", "backend"]' > /dev/null
[[ $(tkt query '.tags | type == "array"' | jq -s length) == 1 ]] || fail 'query filter'
tkt ls --assignee="$assignee" --tag=backend | grep -q "$escaped" || fail 'literal assignee filter'
expect_failure tkt create Bad --assignee $'one\ntwo'
echo 'PASS: JSON and literal metadata'

# Sorting preserves titles and filters before limiting closed results.
TICKETS_DIR_PATH="$TMP/list tickets" tkt create 'left | right' --priority 0 > "$TMP/pipe-id"
TICKETS_DIR_PATH="$TMP/list tickets" tkt ls | grep -Fq 'left | right' || fail 'title separator changed'
TICKETS_DIR_PATH="$TMP/list tickets" tkt close "$(< "$TMP/pipe-id")" > /dev/null
TICKETS_DIR_PATH="$TMP/list tickets" tkt ls --closed | grep -Fq 'left | right' || fail 'closed path with spaces'
(
    export TICKETS_DIR_PATH="$TMP/list tickets"
    cd "$TICKETS_DIR_PATH/.."
    # Fixtures below use .tickets, so use a separate explicit test directory.
    mkdir -p "$TMP/closed/.tickets"
    cd "$TMP/closed"
    TICKETS_DIR_PATH="$PWD/.tickets"
    fixture old closed
    touch -t 200001010000 .tickets/old.md
    fixture newer closed
    for ((i=0; i<105; i++)); do fixture "open-$i"; done
    [[ $(tkt ls --closed --limit=1) == newer* ]] || fail 'closed order or limit'
    tkt ls --closed --limit=200 | grep -q '^old ' || fail 'closed ticket omitted'
    [[ -z $(tkt ls --closed --limit=0) ]] || fail 'zero limit'
    expect_failure tkt ls --limit=no
)
echo 'PASS: listing and closed limits'

# A shared dependency expands once by default. Cycles remain visible and terminate.
(
    mkdir -p "$TMP/graph/.tickets"
    cd "$TMP/graph"
    fixture a open '[b, c]'
    fixture b open '[d]'
    fixture c open '[d]'
    fixture d open '[a]'
    tkt dep tree a > "$TMP/tree"
    grep -q '(seen)' "$TMP/tree" || fail 'shared dependency marker'
    grep -q '(cycle)' "$TMP/tree" || fail 'tree cycle marker'
    tkt dep tree --full a > "$TMP/tree-full"
    [[ $(grep -c '(cycle)' "$TMP/tree-full") == 2 ]] || fail 'full tree expansion'
    tkt dep cycle | grep -q 'a -> b -> d -> a' || fail 'cycle detection'
    tkt close d > /dev/null
    [[ $(tkt dep cycle) == 'No dependency cycles found' ]] || fail 'closed cycle member'
    tkt ls --ready | grep -q '^b ' || fail 'ready dependency'
    tkt ls --blocked | grep -q '^a ' || fail 'blocked dependency'
    tkt cat d | grep -q '^## Blocking' || fail 'inverse dependency display'
)
echo 'PASS: graph traversal'

# Force ID collisions to verify retry and preservation of existing tickets.
(
    mkdir -p "$TMP/collision/.tickets" "$TMP/bin"
    cd "$TMP/collision"
    fixture col-000000000001
    cp .tickets/col-000000000001.md "$TMP/collision-before"
    cat > "$TMP/bin/od" <<'EOF'
#!/usr/bin/env bash
n=0
[[ ! -f "$TKT_TEST_COUNTER" ]] || read -r n < "$TKT_TEST_COUNTER"
printf '%s\n' "$((n + 1))" > "$TKT_TEST_COUNTER"
printf '%012x\n' "$((n / 2 + 1))"
EOF
    chmod +x "$TMP/bin/od"
    id=$(PATH="$TMP/bin:$PATH" TKT_TEST_COUNTER="$TMP/counter" tkt create New)
    [[ "$id" == col-000000000002 ]] || fail 'collision retry'
    cmp .tickets/col-000000000001.md "$TMP/collision-before" || fail 'collision overwrote ticket'
    [[ -f ".tickets/$id.md" ]] || fail 'new ticket missing'
    fixture col-000000000003 closed
    mkdir .tickets/archive
    mv .tickets/col-000000000003.md .tickets/archive/
    id=$(PATH="$TMP/bin:$PATH" TKT_TEST_COUNTER="$TMP/counter" tkt create Another)
    [[ "$id" == col-000000000004 && -f .tickets/archive/col-000000000003.md ]] || fail 'archived ID reused'
    [[ $(find .tickets -name '.create.*' | wc -l | tr -d ' ') == 0 ]] || fail 'creation temporary file left'
)
echo 'PASS: exclusive creation and collision retry'

# Archive follows transitive relationships and refuses to overwrite old data.
(
    mkdir -p "$TMP/archive/.tickets"
    cd "$TMP/archive"
    fixture active open '[closed]'
    fixture closed closed '[transitive]'
    fixture transitive closed
    fixture isolated closed
    tkt archive > /dev/null
    [[ -f .tickets/archive/isolated.md && -f .tickets/transitive.md ]] || fail 'archive reachability'
    fixture isolated closed
    cp .tickets/archive/isolated.md "$TMP/archive-before"
    expect_failure tkt archive
    cmp .tickets/archive/isolated.md "$TMP/archive-before" || fail 'archive overwritten'
    [[ -f .tickets/isolated.md ]] || fail 'archive collision removed source'
)
echo 'PASS: safe archive'

# Empty stores must not hang on stdin or hide awk errors.
(
    export TICKETS_DIR_PATH="$TMP/empty"
    [[ -z $(tkt query) ]] || fail 'empty query'
    [[ $(tkt dep cycle) == 'No dependency cycles found' ]] || fail 'empty cycle check'
    expect_failure tkt create --priority
    expect_failure tkt ls --unknown
)
echo 'PASS: empty stores and argument errors'
echo 'All tests passed'
