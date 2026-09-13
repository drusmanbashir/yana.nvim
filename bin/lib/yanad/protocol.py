VERSION = 1


def ok(frame_id, result=None):
    return {"v": VERSION, "id": frame_id, "ok": True, "result": result or {}}


def refuse(frame_id, code, result=None):
    return {"v": VERSION, "id": frame_id, "ok": False, "code": code, "result": result or {}}
