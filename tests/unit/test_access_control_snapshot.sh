# shellcheck shell=bash
# the pure parts of lib/access_control_snapshot.py: the kernel list format, which lists a grant must
# refuse, and what a path's list becomes when the grant's entries are taken off. the file work (open,
# walk, read and write the attribute) only runs on linux and is covered by tests/harness.

SNAPSHOT_PY="$REPO_DIR/lib/access_control_snapshot.py"

# snapshot_python SCRIPT: run SCRIPT with the helper loaded as module h.
snapshot_python() {
  SNAPSHOT_PY="$SNAPSHOT_PY" python3 -I -c '
import importlib.util, os
spec = importlib.util.spec_from_file_location("h", os.environ["SNAPSHOT_PY"])
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
'"$1" 2>&1
}

test_list_format_round_trips_in_the_order_the_kernel_wants() {
  assert_eq "ok" "$(snapshot_python '
entries = [(h.OTHER, 4, h.NO_ID), (h.MASK, 6, h.NO_ID), (h.USER, 6, 1002), (h.USER_OBJ, 6, h.NO_ID), (h.GROUP_OBJ, 4, h.NO_ID), (h.USER, 4, 1001)]
raw = h.build(entries)
tags = [tag for tag, _, _ in h.parse(raw)]
ids = [number for tag, _, number in h.parse(raw) if tag == h.USER]
assert tags == [1, 2, 2, 4, 16, 32], tags
assert ids == [1001, 1002], ids
print("ok")')"
}

test_a_list_with_an_unknown_format_is_a_failure_not_a_guess() {
  assert_contains "$(snapshot_python '
try:
    h.parse(b"\x01\x00\x00\x00")
except h.Failure as error:
    print("refused:", error)')" "refused:"
}

test_lists_for_other_accounts_or_a_mask_alone_are_refused() {
  assert_eq "ok" "$(snapshot_python '
ours = {1002, 1001}
base = [(h.USER_OBJ, 6, h.NO_ID), (h.GROUP_OBJ, 4, h.NO_ID), (h.OTHER, 4, h.NO_ID)]
assert h.problems_in(base, ours, "access") == []
assert h.problems_in(None, ours, "access") == []
bob = base + [(h.USER, 6, 1500), (h.MASK, 4, h.NO_ID)]
assert len(h.problems_in(bob, ours, "access")) == 1
group = base + [(h.GROUP, 4, 200), (h.MASK, 4, h.NO_ID)]
assert "group" in h.problems_in(group, ours, "access")[0]
mask_only = base + [(h.MASK, 4, h.NO_ID)]
assert "mask" in h.problems_in(mask_only, ours, "access")[0]
earlier_grant = base + [(h.USER, 6, 1002), (h.USER, 6, 1001), (h.MASK, 6, h.NO_ID)]
assert h.problems_in(earlier_grant, ours, "access") == []
print("ok")')"
}

test_taking_the_grant_off_collapses_to_the_owners_chmod() {
  # a 644 file with the agent's entry; the owner then ran chmod 600, which sets the mask to nothing and
  # leaves the group entry r--. the result must be group nothing, not group r--.
  assert_eq "ok" "$(snapshot_python '
agent, owner = 1002, 1001
after_chmod = [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 6, agent), (h.USER, 6, owner), (h.GROUP_OBJ, 4, h.NO_ID), (h.MASK, 0, h.NO_ID), (h.OTHER, 0, h.NO_ID)]
plain = h.access_without_grant(after_chmod, agent, owner, None)
assert plain == [(h.USER_OBJ, 6, h.NO_ID), (h.GROUP_OBJ, 0, h.NO_ID), (h.OTHER, 0, h.NO_ID)], plain
untouched = [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 6, agent), (h.GROUP_OBJ, 4, h.NO_ID), (h.MASK, 6, h.NO_ID), (h.OTHER, 4, h.NO_ID)]
plain = h.access_without_grant(untouched, agent, owner, None)
assert plain == [(h.USER_OBJ, 6, h.NO_ID), (h.GROUP_OBJ, 4, h.NO_ID), (h.OTHER, 4, h.NO_ID)], plain
print("ok")')"
}

test_a_path_without_the_grants_entries_is_left_alone() {
  assert_eq "ok" "$(snapshot_python '
agent, owner = 1002, 1001
someone_elses = [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 4, 1500), (h.GROUP_OBJ, 4, h.NO_ID), (h.MASK, 4, h.NO_ID), (h.OTHER, 0, h.NO_ID)]
assert h.access_without_grant(someone_elses, agent, owner, None) is None
# the folder owner entry alone, with no entry of the agent, is not the grant
owner_only = [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 6, owner), (h.GROUP_OBJ, 4, h.NO_ID), (h.MASK, 6, h.NO_ID), (h.OTHER, 0, h.NO_ID)]
assert h.access_without_grant(owner_only, agent, owner, None) is None
print("ok")')"
}

test_entries_of_an_earlier_grant_come_back_with_a_mask_no_wider_than_before() {
  assert_eq "ok" "$(snapshot_python '
import base64
agent, owner = 1002, 1001
earlier = [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 4, agent), (h.GROUP_OBJ, 0, h.NO_ID), (h.MASK, 4, h.NO_ID), (h.OTHER, 0, h.NO_ID)]
blob = base64.b64encode(h.build(earlier)).decode()
now = [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 6, agent), (h.GROUP_OBJ, 0, h.NO_ID), (h.MASK, 6, h.NO_ID), (h.OTHER, 0, h.NO_ID)]
back = h.access_without_grant(now, agent, owner, blob)
assert back == [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 4, agent), (h.GROUP_OBJ, 0, h.NO_ID), (h.MASK, 4, h.NO_ID), (h.OTHER, 0, h.NO_ID)], back
print("ok")')"
}

test_granting_a_plain_file_adds_the_agent_and_a_mask_like_setfacl() {
  # a 644 file, builder rwX: agent rw-, X adds nothing on a file with no execute bit, the mask is the group class union.
  assert_eq "ok" "$(snapshot_python '
agent = 1002
wanted = h.access_with_grant(None, 0o644, False, agent, "rwX")
assert wanted == [(h.USER_OBJ, 6, h.NO_ID), (h.USER, 6, agent), (h.GROUP_OBJ, 4, h.NO_ID), (h.MASK, 6, h.NO_ID), (h.OTHER, 4, h.NO_ID)], wanted
# a folder gets execute from X; an already executable file gets it too; observer rX is read only
assert h.access_with_grant(None, 0o755, True, agent, "rX")[1] == (h.USER, 5, agent)
assert h.access_with_grant(None, 0o755, False, agent, "rX")[1] == (h.USER, 5, agent)
assert h.access_with_grant(None, 0o600, False, agent, "rX")[1] == (h.USER, 4, agent)
# a pass-through parent: execute only
assert h.access_with_grant(None, 0o700, True, agent, "x")[1] == (h.USER, 1, agent)
# granting twice changes nothing
once = h.access_with_grant(None, 0o644, False, agent, "rwX")
assert h.access_with_grant(once, 0o664, False, agent, "rwX") == once
print("ok")')"
}

test_the_default_list_gives_group_and_other_nothing_and_the_owner_the_grant() {
  assert_eq "ok" "$(snapshot_python '
agent, owner = 1002, 1001
wanted = h.default_with_grant(None, None, 0o755, agent, owner, "rwX")
assert wanted == [(h.USER_OBJ, 7, h.NO_ID), (h.USER, 7, owner), (h.USER, 7, agent), (h.GROUP_OBJ, 0, h.NO_ID), (h.MASK, 7, h.NO_ID), (h.OTHER, 0, h.NO_ID)], wanted
# an owner of root or the agent itself is not added
assert not [e for e in h.default_with_grant(None, None, 0o755, agent, 0, "rwX") if e[0] == h.USER and e[2] == 0]
assert len([e for e in h.default_with_grant(None, None, 0o755, agent, agent, "rwX") if e[0] == h.USER]) == 1
# an earlier base-only default list keeps its owner entry but loses group and other
earlier = [(h.USER_OBJ, 7, h.NO_ID), (h.GROUP_OBJ, 5, h.NO_ID), (h.OTHER, 5, h.NO_ID)]
after = h.default_with_grant(earlier, None, 0o755, agent, owner, "rX")
assert (h.GROUP_OBJ, 0, h.NO_ID) in after and (h.OTHER, 0, h.NO_ID) in after and (h.USER, 5, agent) in after, after
print("ok")')"
}
