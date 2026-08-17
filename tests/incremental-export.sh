#!/bin/bash
#
# Tests for incremental HTML writes and capture-failure detection.
#
# Usage: tests/incremental-export.sh [/path/to/messages-exporter.php] [php-binary]
#
# Builds throwaway fixtures in a temp directory and never touches a real
# Messages database or a real export directory.

SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/messages-exporter.php}"
PHP="${2:-php}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# High-precision mtimes: APFS records sub-second times, and without them two
# runs inside the same second would look identical even when files are rewritten.
snapshot() {
	find "$1" -maxdepth 1 -type f -name '*.html' -exec stat -f '%Fm %N' {} + 2>/dev/null | sort
}

apple_ns() {
	# Apple epoch: nanoseconds since 2001-01-01.
	echo "(strftime('%s','$1') - 978307200) * 1000000000"
}

build_fixture() {
	# A minimal but realistic chat.db: two conversations, one of them a group.
	local db="$1"
	rm -f "$db"

	sqlite3 "$db" <<-'SQL'
		CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, country TEXT, service TEXT, uncanonicalized_id TEXT);
		CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, state INTEGER, chat_identifier TEXT, service_name TEXT, room_name TEXT, display_name TEXT);
		CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER, service TEXT, date INTEGER, is_from_me INTEGER, cache_has_attachments INTEGER, balloon_bundle_id TEXT);
		CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT);
		CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
		CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
		CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
	SQL

	sqlite3 "$db" <<-SQL
		INSERT INTO handle (ROWID, id, service) VALUES
			(1, '+15550000001', 'iMessage'),
			(2, '+15550000002', 'iMessage');

		INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name) VALUES
			(1, 'iMessage;-;+15550000001', 45, '+15550000001', 'iMessage'),
			(2, 'iMessage;+;chat0001',     43, 'chat0001',     'iMessage');

		INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, cache_has_attachments) VALUES
			(1, 'FIX-0001', 'First message in the one-to-one chat.', 1, 'iMessage', $(apple_ns '2020-03-01 09:00:00'), 0, 0),
			(2, 'FIX-0002', 'A reply from me.',                     1, 'iMessage', $(apple_ns '2020-03-01 09:01:00'), 1, 0),
			(3, 'FIX-0003', 'Group message from the first handle.', 1, 'iMessage', $(apple_ns '2020-04-05 12:00:00'), 0, 0),
			(4, 'FIX-0004', 'Group message from the second handle.',2, 'iMessage', $(apple_ns '2020-04-05 12:30:00'), 0, 0),
			-- handle_id 0 has no matching handle row, so the LEFT JOIN yields a NULL
			-- contact. 11,753 rows in the real archive look like this, and they are
			-- what trips the "null as an array offset" deprecation.
			(10,'FIX-0010', 'Sent message with no handle row.',    0, 'iMessage', $(apple_ns '2020-03-01 09:02:00'), 1, 0);

		INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1,1), (2,1), (2,2);

		INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES
			(1, 1, $(apple_ns '2020-03-01 09:00:00')),
			(1, 2, $(apple_ns '2020-03-01 09:01:00')),
			(1, 10, $(apple_ns '2020-03-01 09:02:00')),
			(2, 3, $(apple_ns '2020-04-05 12:00:00')),
			(2, 4, $(apple_ns '2020-04-05 12:30:00'));
	SQL
}

run_export() {
	# -d keeps attachment handling out of the picture, which is what we want here.
	"$PHP" "$SCRIPT" -o "$1" -d "$2" 2>&1
}

echo "Testing: $SCRIPT"
echo "PHP:     $($PHP --version 2>&1 | head -1)"
echo

# ---------------------------------------------------------------------------
echo "TEST 1: a re-run with no new messages leaves every HTML file untouched"
OUT1="$WORK/out1"
FIX1="$WORK/fixture1.db"
mkdir -p "$OUT1"
build_fixture "$FIX1"

run_export "$OUT1" "$FIX1" > "$WORK/run1.log" 2>&1
BEFORE="$(snapshot "$OUT1")"
COUNT="$(echo "$BEFORE" | grep -c .)"

if [ "$COUNT" -eq 0 ]; then
	fail "fixture produced no HTML files; cannot test (see $WORK/run1.log)"
	head -20 "$WORK/run1.log"
else
	sleep 1.1
	run_export "$OUT1" "$FIX1" > "$WORK/run2.log" 2>&1
	AFTER="$(snapshot "$OUT1")"

	if [ "$BEFORE" = "$AFTER" ]; then
		pass "$COUNT HTML file(s) untouched on re-run"
	else
		CHANGED="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | grep -c .)"
		fail "$CHANGED of $COUNT HTML file(s) were rewritten despite no new messages"
	fi
fi

# ---------------------------------------------------------------------------
echo "TEST 2: a new message rewrites only the affected conversation"
if [ "${COUNT:-0}" -gt 1 ]; then
	sqlite3 "$FIX1" "
		INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, cache_has_attachments)
		VALUES (5, 'FIX-0005', 'A brand new message arrives.', 1, 'iMessage', $(apple_ns '2020-03-02 10:00:00'), 0, 0);
		INSERT INTO chat_message_join (chat_id, message_id, message_date)
		VALUES (1, 5, $(apple_ns '2020-03-02 10:00:00'));
	"

	BEFORE2="$(snapshot "$OUT1")"
	sleep 1.1
	run_export "$OUT1" "$FIX1" > "$WORK/run3.log" 2>&1
	AFTER2="$(snapshot "$OUT1")"

	CHANGED2="$(comm -13 <(echo "$BEFORE2") <(echo "$AFTER2") | grep -c .)"
	if [ "$CHANGED2" -eq 1 ]; then
		pass "exactly 1 HTML file changed"
	else
		fail "expected exactly 1 changed HTML file, got $CHANGED2"
	fi
else
	fail "skipped; TEST 1 did not produce multiple HTML files"
fi

# ---------------------------------------------------------------------------
echo "TEST 3: a source database with no messages is reported as a failure"
OUT3="$WORK/out3"
FIX3="$WORK/fixture3.db"
mkdir -p "$OUT3"
build_fixture "$FIX3"
# Mirror the real-world failure: conversations survive, message bodies do not.
sqlite3 "$FIX3" "DELETE FROM message; DELETE FROM chat_message_join;"

OUTPUT="$(run_export "$OUT3" "$FIX3" 2>&1)"
EXIT=$?

if [ "$EXIT" -ne 0 ]; then
	pass "exited non-zero (exit $EXIT) on an empty source database"
else
	fail "exited 0 on an empty source database; a silent failure is undetectable"
fi

# ---------------------------------------------------------------------------
echo "TEST 4: a normal run produces no PHP warnings or notices"
if grep -qiE 'deprecated|warning|notice|fatal' "$WORK/run1.log"; then
	fail "$(grep -ciE 'deprecated|warning|notice|fatal' "$WORK/run1.log") warning line(s) on stderr/stdout"
	grep -iE 'deprecated|warning|notice|fatal' "$WORK/run1.log" | head -3
else
	pass "output clean"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
	echo "All tests passed."
	exit 0
else
	echo "$FAILURES test(s) failed."
	exit 1
fi
