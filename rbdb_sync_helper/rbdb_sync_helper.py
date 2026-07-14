#!/usr/bin/env python3
"""rbdb-sync-helper — записывает overlay-плейлисты Rimeo в базу Rekordbox.

    rbdb-sync-helper <master.db path> <plan.json> <out.json>

ПОЧЕМУ ОТДЕЛЬНЫЙ БИНАРЬ, А НЕ SWIFT
-----------------------------------
Запись в master.db ломается не тогда, когда падает, а когда ТИХО ПРОХОДИТ,
а Rekordbox при следующем старте её игнорирует или затирает. Три инварианта,
промах по любому из которых даёт именно такой исход:

  1. USN (agentRegistry.localUpdateCount + per-row rb_local_usn) — счётчик
     изменений. Не сдвинул → Rekordbox считает правку устаревшей; при включённом
     облачном синке — конфликт на всех устройствах.
  2. masterPlaylists6.xml — второй обязательный манифест рядом с базой.
     Не обновил → плейлистов просто не видно.
  3. Типы ID: djmdPlaylist.ID — 28-битный int-как-строка; djmdSongPlaylist.ID
     и .UUID — uuid4.

pyrekordbox делает все три из коробки (db.commit() → autoinc USN + XML-sync +
валидация ID). Ручной порт этого на Swift — самый широкий corruption-surface
в проекте, и verify-по-reparse его НЕ ловит: строки физически в файле, агент
пометит synced, а Rekordbox отвергнет позже.

ДВА БАРЬЕРА
-----------
Барьер 1 (Swift-родитель, до нас): Rekordbox не запущен (NSWorkspace).
Барьер 2 (здесь, первым делом): lock-probe BEGIN IMMEDIATE. Закрывает гонку
«юзер закрыл Rekordbox прямо сейчас» — процесс уже мёртв, а лок ещё держится.

LIVE-DELTA — ГЛАВНАЯ ЗАЩИТА ОТ ДУБЛЕЙ
-------------------------------------
Состав считается ТОЛЬКО из живого чтения базы в том же соединении, НИКОГДА из
overlay. overlay.track_ids — это ЖЕЛАЕМОЕ КОНЕЧНОЕ СОСТОЯНИЕ, а не список
операций: юзер мог править тот же плейлист прямо в Rekordbox.

    live    = [ContentID из djmdSongPlaylist ORDER BY TrackNo]   # из БД СЕЙЧАС
    desired = dedup(overlay.track_ids)
    toAdd    = desired \\ live      (в порядке desired)
    toRemove = live \\ desired
    reorder  = после add/remove: desired-порядок != TrackNo

Повторный Sync без изменений → toAdd = toRemove = ∅ → база не трогается.
Дубли невозможны by construction, а не потому что мы аккуратно посчитали.
"""

import json
import sys
import uuid


def fail(code, detail=""):
    """Понятная ошибка вместо stack-trace — её увидит iOS-юзер."""
    print(json.dumps({"error": code, "detail": detail}), file=sys.stderr)
    sys.exit(1)


def emit(**kw):
    """Стадия прогресса → одна JSON-строка в stdout, немедленно.

    Агент читает stdout построчно и отдаёт это телефону (`/api/playlist/sync/status`),
    чтобы прогресс был ЧЕСТНЫМ. Без этого UI мог бы только крутить спиннер и врать.
    Итоговый результат прогона едет НЕ здесь, а в out.json — stdout только под прогресс.
    """
    sys.stdout.write(json.dumps({"progress": kw}) + "\n")
    sys.stdout.flush()


def preflight():
    """Импорты первым делом: если бинарь собран криво, лучше узнать сразу
    и понятной ошибкой, а не падением посреди записи в чужую базу."""
    try:
        import pyrekordbox  # noqa: F401
        import sqlalchemy   # noqa: F401
        import sqlcipher3   # noqa: F401
    except ImportError as e:
        fail("helper_unavailable", str(e))


def open_db(db_path):
    """Открыть базу СТРОГО по переданному пути.

    ⚠️ ГРАБЛИ, СТОИВШИЕ БОЕВОЙ БАЗЫ (13.07.2026):
    сигнатура — Rekordbox6Database(path=None, db_dir='', key='', unlock=True).
    `db_dir` — это НЕ путь к базе (он про вспомогательные XML). Если передать
    только его, `path` остаётся None, и библиотека молча берёт путь ИЗ КОНФИГА
    REKORDBOX — то есть боевую базу юзера. Именно так тестовый прогон,
    «изолированный» в песочнице, записал мусор в реальную библиотеку.

    Поэтому: path= передаём ЯВНО и СРАЗУ ЖЕ СВЕРЯЕМ, что библиотека открыла
    именно его. Разъехалось — падаем, не написав ни байта.
    """
    import os
    from pyrekordbox import Rekordbox6Database

    want = os.path.realpath(db_path)
    if not os.path.exists(want):
        fail("db_not_found", want)

    try:
        db = Rekordbox6Database(path=want)
    except Exception as e:
        fail("db_open_failed", str(e))

    # Параноидальная сверка: куда библиотека реально смотрит.
    try:
        got = os.path.realpath(str(db.engine.url.database))
    except Exception:
        got = None
    if got and got != want:
        fail("db_path_mismatch", f"просили {want}, открылась {got}")

    return db


def lock_probe(db):
    """БАРЬЕР 2. Пытаемся взять эксклюзивную блокировку. Если база под локом —
    Rekordbox ещё жив (или не отпустил файл). Выходим, НЕ ТРОНУВ базу: родитель
    увидит rekordbox_running и вернёт 409, откатывать будет нечего."""
    try:
        conn = db.engine.raw_connection()
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("ROLLBACK")
        finally:
            conn.close()
    except Exception as e:
        msg = str(e).lower()
        if "locked" in msg or "busy" in msg:
            fail("rekordbox_running", "database is locked")
        fail("lock_probe_failed", str(e))


def live_songs(db, playlist_id):
    """Живой состав плейлиста ИЗ БАЗЫ, в порядке TrackNo. Единственный источник
    правды для дельты — см. шапку модуля."""
    rows = db.get_playlist_songs(PlaylistID=playlist_id).all()
    rows = sorted(rows, key=lambda s: s.TrackNo or 0)
    return [(str(s.ContentID), s) for s in rows]


def dedup(seq):
    """Дедуп с сохранением порядка."""
    seen, out = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def by_id(getter, ident):
    """pyrekordbox при фильтре по первичному ключу возвращает САМ ОБЪЕКТ,
    а не Query — .one_or_none() на нём падает AttributeError. Без фильтра —
    наоборот, Query. Прячем эту асимметрию здесь, чтобы не наступать дважды."""
    if not ident:
        return None
    try:
        obj = getter(ID=str(ident))
    except Exception:
        return None
    # На всякий случай: если всё же прилетел Query — развернём.
    if hasattr(obj, "one_or_none"):
        return obj.one_or_none()
    return obj


def apply_membership(db, pl, desired, result):
    """Живая дельта состава. Возвращает (added, removed, reordered)."""
    live = live_songs(db, pl.ID)
    live_ids = [cid for cid, _ in live]
    live_by_id = {cid: row for cid, row in live}

    desired = dedup(desired)
    to_add = [t for t in desired if t not in live_by_id]
    to_remove = [cid for cid in live_ids if cid not in set(desired)]

    for cid in to_remove:
        # remove_from_playlist принимает СТРОКУ djmdSongPlaylist, а не ContentID.
        db.remove_from_playlist(pl, live_by_id[cid])

    contents = {}
    if to_add:
        for cid in to_add:
            c = by_id(db.get_content, cid)
            if c is None:
                result.setdefault("skipped", []).append(cid)  # трека нет в базе
                continue
            contents[cid] = c
            db.add_to_playlist(pl, c)

    db.commit()

    # Порядок — точечными move, только если реально разъехался.
    reordered = 0
    if desired:
        cur = [cid for cid, _ in live_songs(db, pl.ID)]
        target = [t for t in desired if t in set(cur)]
        if cur != target:
            for want_pos, cid in enumerate(target, start=1):
                rows = {c: r for c, r in live_songs(db, pl.ID)}
                row = rows.get(cid)
                if row is None:
                    continue
                if (row.TrackNo or 0) != want_pos:
                    db.move_song_in_playlist(pl, row, want_pos)
                    reordered += 1
            db.commit()

    return len(contents), len(to_remove), reordered


def main():
    if len(sys.argv) != 4:
        fail("usage", "rbdb-sync-helper <master.db> <plan.json> <out.json>")

    preflight()

    db_path, plan_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        plan = json.load(open(plan_path))
    except Exception as e:
        fail("bad_plan", str(e))

    # Открытие строго по переданному пути + сверка (см. open_db).
    db = open_db(db_path)

    lock_probe(db)

    emit(stage="writing", tracks_done=0, tracks_total=0)

    usn_before = db.get_local_usn()
    results = []
    # Сколько треков предстоит тронуть — для честного «2 из 3» на экране.
    tracks_total = sum(len(op.get("desired") or []) for op in plan.get("ops", []))
    tracks_done = 0
    # rimeo_id → новый rekordbox_id. Нужен, чтобы дети pending-папки нашли
    # родителя, чей ID появляется только в этом же прогоне.
    id_map = {}

    for op in plan.get("ops", []):
        t = op.get("type")
        rimeo_id = op.get("rimeo_id")
        rb_id = op.get("rekordbox_id")
        r = {"rimeo_id": rimeo_id, "ok": False, "added": 0, "removed": 0, "reordered": 0}

        try:
            # Родитель: сначала явный rekordbox_id, иначе — из карты этого прогона.
            parent = op.get("parent_rekordbox_id")
            if not parent and op.get("parent_rimeo_id"):
                parent = id_map.get(op["parent_rimeo_id"])
            parent_obj = by_id(db.get_playlist, parent) if parent else None

            # ⚠️ seq=1 — НАВЕРХ списка, а не в конец.
            # pyrekordbox при seq=None ставит max+1 (то есть в самый низ), и новый
            # плейлист терялся среди сотен старых. При seq=1 библиотека САМА сдвигает
            # остальные (`Seq >= seq → Seq += 1`), так что ничего не ломается.
            # Граблю ловили 13.07: фикс был показан в разовом скрипте и не доехал сюда.
            if t == "create_folder":
                pl = db.create_playlist_folder(op["name"], parent=parent_obj, seq=1)
                db.commit()
                id_map[rimeo_id] = str(pl.ID)
                r.update(ok=True, rekordbox_id=str(pl.ID))

            elif t == "create_playlist":
                pl = db.create_playlist(op["name"], parent=parent_obj, seq=1)
                db.commit()
                id_map[rimeo_id] = str(pl.ID)
                a, rm, ro = apply_membership(db, pl, op.get("desired") or [], r)
                r.update(ok=True, rekordbox_id=str(pl.ID), added=a, removed=rm, reordered=ro)
                tracks_done += len(op.get("desired") or [])
                emit(stage="writing", tracks_done=tracks_done, tracks_total=tracks_total)

            elif t == "membership":
                pl = by_id(db.get_playlist, rb_id)
                if pl is None:
                    r["reason"] = "playlist_not_found"
                else:
                    a, rm, ro = apply_membership(db, pl, op.get("desired") or [], r)
                    r.update(ok=True, rekordbox_id=str(pl.ID), added=a, removed=rm, reordered=ro)
                    tracks_done += len(op.get("desired") or [])
                    emit(stage="writing", tracks_done=tracks_done, tracks_total=tracks_total)

            elif t == "rename":
                pl = by_id(db.get_playlist, rb_id)
                if pl is None:
                    r["reason"] = "playlist_not_found"
                else:
                    db.rename_playlist(pl, op["name"])
                    db.commit()
                    r.update(ok=True, rekordbox_id=str(pl.ID))

            elif t == "delete":
                pl = by_id(db.get_playlist, rb_id)
                if pl is None:
                    r.update(ok=True, reason="already_gone")   # идемпотентно
                else:
                    db.delete_playlist(pl)
                    db.commit()
                    r.update(ok=True)

            else:
                r["reason"] = f"unknown_op:{t}"

        except Exception as e:
            r["reason"] = f"{type(e).__name__}: {e}"

        results.append(r)

    # WAL → в сам master.db. Без этого: (а) mtime-кеш агента прячет запись,
    # (б) Rekordbox видит чужой несведённый WAL.
    try:
        conn = db.engine.raw_connection()
        emit(stage="checkpoint")
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.close()
    except Exception:
        pass

    usn_after = db.get_local_usn()

    out = {
        "ops": results,
        "usn_before": usn_before,
        "usn_after": usn_after,
        # USN обязан сдвинуться, если что-то писали. Не сдвинулся → Rekordbox
        # правку отвергнет, и родитель должен это увидеть.
        "usn_advanced": usn_after > usn_before,
    }
    json.dump(out, open(out_path, "w"), ensure_ascii=False, indent=2)
    print(json.dumps({"status": "ok", "ops": len(results)}))


if __name__ == "__main__":
    main()
