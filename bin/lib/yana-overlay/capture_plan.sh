#!/usr/bin/env bash
# shellcheck shell=bash
# CapturePlan v1 writer and validator for bin/yana-overlay.
# Sourced by launcher/inner helpers only.

capture_plan_mode_valid() {
	case "$1" in
		auto|overlayfs-fast|fuse-compat|off) return 0 ;;
		*) return 1 ;;
	esac
}

capture_plan_backend_for() {
	local project=$1 mode=$2
	case "$mode" in
		overlayfs-fast|fuse-compat) printf '%s\n' "$mode"; return 0 ;;
		auto) ;;
		off) printf '%s\n' off; return 0 ;;
		*) printf '%s\n' open_capture_mode_invalid; return 64 ;;
	esac
	python3 - "$project" <<'PY'
import os
import re
import sys

def dec(value):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), value)

def inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)

project = os.path.abspath(sys.argv[1])
backend = "overlayfs-fast"
with open("/proc/self/mountinfo", encoding="utf-8", errors="surrogateescape") as stream:
    for line in stream:
        fields = line.rstrip("\n").split()
        if len(fields) < 10 or "-" not in fields:
            continue
        mp = os.path.abspath(dec(fields[4]))
        if mp != project and inside(mp, project):
            backend = "fuse-compat"
            break
print(backend)
PY
}

capture_plan_build() {
	local project_cwd=$1 state_root=$2 mode=$3 session_id=$4 turn_id=$5
	capture_plan_mode_valid "$mode" || { echo "open_capture_mode_invalid" >&2; return 64; }
	local backend
	backend=$(capture_plan_backend_for "$project_cwd" "$mode") || return $?
	[[ "$backend" != off ]] || { echo "open_capture_backend_unavailable" >&2; return 65; }
	local dir plan tmp
	dir="$state_root/sessions/$session_id/turns/$turn_id/capture"
	plan="$dir/plan.v1.json"
	tmp="$dir/.plan.$$.$RANDOM"
	mkdir -p "$dir"
	python3 - "$project_cwd" "$state_root" "$mode" "$backend" "$session_id" "$turn_id" "$tmp" <<'PY'
import json
import os
import re
import sys

project, state, mode, backend, sid, tid, tmp = sys.argv[1:]
project = os.path.abspath(project)
state = os.path.abspath(state)
proposal_root = os.path.abspath(os.environ.get("YANA_CAPTURE_UPPER") or os.path.join(state, "sessions", sid, "turns", tid, "capture", "proposal"))

def dec(value):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), value)

def clean(path):
    return os.path.abspath(os.path.normpath(path))

def inside(path, root):
    path = clean(path)
    root = clean(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)

def devino(path):
    st = os.stat(path)
    return f"{st.st_dev}:{st.st_ino}"

def strip_abs(path):
    return clean(path).lstrip(os.sep)

mounts = []
with open("/proc/self/mountinfo", encoding="utf-8", errors="surrogateescape") as stream:
    for line in stream:
        fields = line.rstrip("\n").split()
        if "-" not in fields or len(fields) < 10:
            continue
        sep = fields.index("-")
        opts = fields[5]
        mounts.append({
            "mount_id": int(fields[0]),
            "parent_id": int(fields[1]),
            "major_minor": fields[2],
            "root": clean(dec(fields[3])),
            "mount_point": clean(dec(fields[4])),
            "fs_type": fields[sep + 1],
            "source": dec(fields[sep + 2]) if len(fields) > sep + 2 else "",
            "mount_options": opts,
            "super_options": ",".join(fields[sep + 3:]) if len(fields) > sep + 3 else "",
            "read_only": "ro" in opts.split(","),
        })

def covering_mount(path):
    covers = [m for m in mounts if inside(path, m["mount_point"])]
    if not covers:
        return None
    return max(covers, key=lambda m: len(m["mount_point"]))

def source_for(row):
    choices = []
    for base in mounts:
        if base["mount_id"] == row["mount_id"] or base["major_minor"] != row["major_minor"]:
            continue
        if not inside(row["root"], base["root"]):
            continue
        rel = os.path.relpath(row["root"], base["root"])
        source = base["mount_point"] if rel == "." else clean(os.path.join(base["mount_point"], rel))
        if source == row["mount_point"] or not os.path.exists(source):
            continue
        choices.append((len(base["root"]), base, source))
    if not choices:
        return None, ""
    _, base, source = max(choices, key=lambda item: item[0])
    return base, source

cover = covering_mount(project)
if cover is None:
    raise SystemExit("open_capture_storage")
refusals = []
aliases = []
for row in sorted(mounts, key=lambda m: (m["mount_point"].count(os.sep), len(m["mount_point"])), reverse=True):
    mp = row["mount_point"]
    if not inside(mp, project):
        continue
    if row["root"] == "/":
        continue
    base, source = source_for(row)
    if base is None:
        refusals.append("open_capture_bind_alias")
        continue
    try:
        alias_id = devino(mp)
        source_id = devino(source)
    except OSError:
        refusals.append("open_capture_bind_alias")
        continue
    if alias_id != source_id:
        refusals.append("open_capture_bind_alias")
        continue
    if inside(mp, state) or inside(source, state):
        refusals.append("open_capture_bind_alias")
        continue
    aliases.append({
        "alias_prefix": mp,
        "source_prefix": source,
        "alias_mount_id": row["mount_id"],
        "source_mount_id": base["mount_id"],
        "alias_dev_ino": alias_id,
        "source_dev_ino": source_id,
        "reconstructed_private_abs": os.path.join(proposal_root, ".yana-decoded", strip_abs(source), "f.txt"),
    })

decoded = aliases[0]["source_prefix"] if aliases and aliases[0]["alias_prefix"] == project else project
target_mount = covering_mount(project)
target = {
    "original_abs": project,
    "decoded_real_abs": decoded,
    "private_proposal_abs": proposal_root,
    "mount_order": 0,
    "mount_id": int(target_mount["mount_id"]),
    "dev_ino": devino(project),
    "read_only": bool(target_mount["read_only"]),
}
payload = {
    "version": "open-capture-plan.v1",
    "mode": mode,
    "backend": backend,
    "project_cwd": project,
    "state_root": state,
    "session_id": sid,
    "turn_id": tid,
    "targets": [target],
    "mounts": mounts,
    "aliases": aliases,
}
if refusals:
    payload["refusal"] = sorted(set(refusals))[0]
with open(tmp, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, separators=(",", ":"))
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
PY
	chmod 444 "$tmp"
	mv -f "$tmp" "$plan"
	python3 - "$dir" <<'PY'
import os
import sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
	printf '%s\n' "$plan"
}

capture_plan_field() {
	python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream).get(sys.argv[2], ""))
PY
}

capture_plan_refusal() {
	python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
print(data.get("refusal", ""))
PY
}

capture_plan_read_only_refusal() {
	python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
for target in data.get("targets", []):
    if isinstance(target, dict) and target.get("read_only") is True:
        print("open_capture_read_only_mount")
        raise SystemExit(0)
print("")
PY
}

capture_plan_copy_up_risk_refusal() {
	python3 - "$1" <<'PY'
import json
import os
import stat
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
uid = os.geteuid()
primary_gid = os.getegid()
supplementary = set(os.getgroups()) - {primary_gid}
for target in data.get("targets", []):
    if not isinstance(target, dict):
        continue
    path = target.get("original_abs")
    if not isinstance(path, str) or not path:
        continue
    try:
        st = os.stat(path)
    except OSError:
        continue
    mode = stat.S_IMODE(st.st_mode)
    owner_writable = st.st_uid == uid and bool(mode & stat.S_IWUSR)
    supplementary_writable = st.st_gid in supplementary and bool(mode & stat.S_IWGRP)
    if st.st_uid != uid and not owner_writable and supplementary_writable:
        print("open_capture_copy_up_risk")
        raise SystemExit(0)
print("")
PY
}

capture_plan_validate() {
	local plan=$1 backend=$2 state_root=$3 session_id=$4 turn_id=$5
	python3 - "$plan" "$backend" "$state_root" "$session_id" "$turn_id" <<'PY'
import json
import os
import stat
import sys
plan, backend, state, sid, tid = sys.argv[1:]
def refuse(code):
    print(code)
    raise SystemExit(65)
if os.path.islink(plan):
    refuse("open_capture_storage")
plan_real = os.path.realpath(plan)
state_real = os.path.realpath(state)
want = os.path.join(state_real, "sessions", sid, "turns", tid, "capture", "plan.v1.json")
if plan_real != want:
    refuse("open_capture_storage")
try:
    st = os.stat(plan)
except OSError:
    refuse("open_capture_storage")
if stat.S_IMODE(st.st_mode) & 0o222:
    refuse("open_capture_storage")
try:
    with open(plan, encoding="utf-8") as stream:
        data = json.load(stream)
except Exception:
    refuse("open_capture_storage")
for key in ("version", "mode", "backend", "project_cwd", "state_root", "session_id", "turn_id"):
    if not isinstance(data.get(key), str):
        refuse("open_capture_storage")
if data.get("version") != "open-capture-plan.v1":
    refuse("open_capture_storage")
if data.get("backend") != backend or data.get("session_id") != sid or data.get("turn_id") != tid:
    refuse("open_capture_storage")
if data.get("mode") not in ("auto", "overlayfs-fast", "fuse-compat"):
    refuse("open_capture_storage")
if os.path.realpath(data.get("state_root")) != state_real:
    refuse("open_capture_storage")
if data.get("final_caps"):
    refuse("open_capture_capabilities")
if not isinstance(data.get("targets"), list) or not data["targets"]:
    refuse("open_capture_storage")
if not isinstance(data.get("mounts"), list) or not data["mounts"]:
    refuse("open_capture_storage")
if not isinstance(data.get("aliases"), list):
    refuse("open_capture_storage")
for target in data["targets"]:
    for key, typ in {"original_abs": str, "decoded_real_abs": str, "private_proposal_abs": str, "mount_order": int}.items():
        if not isinstance(target.get(key), typ):
            refuse("open_capture_storage")
    if "mount_id" in target and not isinstance(target.get("mount_id"), int):
        refuse("open_capture_storage")
    if "dev_ino" in target:
        try:
            live = os.stat(target["original_abs"])
        except OSError:
            refuse("open_capture_storage")
        if target["dev_ino"] != f"{live.st_dev}:{live.st_ino}":
            refuse("open_capture_storage")
    if "read_only" in target and not isinstance(target.get("read_only"), bool):
        refuse("open_capture_storage")
for row in data["aliases"]:
    for key, typ in {
        "alias_prefix": str,
        "source_prefix": str,
        "alias_mount_id": int,
        "source_mount_id": int,
        "alias_dev_ino": str,
        "source_dev_ino": str,
        "reconstructed_private_abs": str,
    }.items():
        if not isinstance(row.get(key), typ):
            refuse("open_capture_storage")
    try:
        alias_st = os.stat(row["alias_prefix"])
        source_st = os.stat(row["source_prefix"])
    except OSError:
        refuse("open_capture_bind_alias")
    if row["alias_dev_ino"] != f"{alias_st.st_dev}:{alias_st.st_ino}" or row["source_dev_ino"] != f"{source_st.st_dev}:{source_st.st_ino}" or row["alias_dev_ino"] != row["source_dev_ino"]:
        refuse("open_capture_bind_alias")
print("ok")
PY
}

capture_plan_fuse_missing_dep() {
	command -v fuse-overlayfs >/dev/null 2>&1 || { echo open_capture_dep_fuse_overlayfs; return 0; }
	[[ -c /dev/fuse ]] || { echo open_capture_dep_dev_fuse; return 0; }
	command -v newuidmap >/dev/null 2>&1 || { echo open_capture_dep_newuidmap; return 0; }
	command -v newgidmap >/dev/null 2>&1 || { echo open_capture_dep_newgidmap; return 0; }
	python3 - <<'PY'
print("")
PY
}
