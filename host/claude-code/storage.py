"""Private local persistence for managed sessions and durable prompt receipts."""
import fcntl
import json
import os
import pathlib
import sqlite3
import time
import uuid


def timestamp():
    return int(time.time() * 1000)


class Storage:
    def __init__(self, directory):
        directory = pathlib.Path(directory)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if directory.is_symlink() or directory.stat().st_mode & 0o077:
            raise ValueError('State directory must be private and not a symlink')
        self.lock = os.open(directory / 'adapter.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.lock)
            raise ValueError('Another adapter already owns this state directory') from None
        try:
            self._open_database(directory)
        except BaseException:
            connection = getattr(self, 'connection', None)
            if connection is not None:
                connection.close()
            os.close(self.lock)
            raise

    def _open_database(self, directory):
        database = directory / 'relay.sqlite3'
        if database.is_symlink():
            raise ValueError('Database must not be a symlink')
        descriptor = os.open(database, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        os.chmod(database, 0o600)
        self.connection = sqlite3.connect(database)
        self.connection.row_factory = sqlite3.Row
        self.connection.executescript('''
            PRAGMA journal_mode=DELETE;
            PRAGMA synchronous=FULL;
            PRAGMA foreign_keys=ON;
            PRAGMA max_page_count=65536;
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, directory TEXT NOT NULL,
                updated INTEGER NOT NULL, native_id TEXT
            );
            CREATE TABLE IF NOT EXISTS receipts (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id),
                fingerprint TEXT NOT NULL, state TEXT NOT NULL, created INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                message_id TEXT NOT NULL, payload TEXT NOT NULL,
                UNIQUE(session_id, message_id)
            );
            CREATE INDEX IF NOT EXISTS session_messages ON messages(session_id, sequence);
        ''')
        with self.connection:
            interrupted = self.connection.execute(
                "SELECT id,session_id FROM receipts WHERE state IN ('admitted','running')").fetchall()
            for receipt in interrupted:
                self._append(receipt['session_id'], {
                    'id': 'interrupted_' + receipt['id'], 'role': 'assistant',
                    'parts': [{'type': 'text', 'text':
                               'O adaptador reiniciou durante o turno. O resultado pode estar incompleto; o prompt não foi repetido.'}],
                })
            self.connection.execute(
                "UPDATE receipts SET state='interrupted' WHERE state IN ('admitted','running')")

    def close(self):
        self.connection.close()
        os.close(self.lock)

    def session(self, identifier):
        row = self.connection.execute('SELECT * FROM sessions WHERE id=?', (identifier,)).fetchone()
        return dict(row) if row else None

    def sessions(self):
        return [dict(row) for row in self.connection.execute('SELECT * FROM sessions LIMIT 1000')]

    def create(self, title, directory, native_id=None, history=()):
        if self.connection.execute('SELECT count(*) FROM sessions').fetchone()[0] >= 1000:
            raise ValueError('Session capacity reached')
        identifier = str(uuid.uuid4())
        with self.connection:
            self.connection.execute('INSERT INTO sessions VALUES(?,?,?,?,?)',
                                    (identifier, title, directory, timestamp(), native_id))
            for message in history:
                self._append(identifier, message)
        return self.session(identifier)

    def receipt(self, identifier):
        row = self.connection.execute('SELECT * FROM receipts WHERE id=?', (identifier,)).fetchone()
        return dict(row) if row else None

    def admit(self, session, identifier, fingerprint, text):
        if self.connection.execute('SELECT count(*) FROM receipts').fetchone()[0] >= 10000:
            raise ValueError('Receipt capacity reached')
        message = {'id': identifier, 'role': 'user', 'parts': [{'type': 'text', 'text': text}]}
        with self.connection:
            self.connection.execute('INSERT INTO receipts VALUES(?,?,?,?,?)',
                                    (identifier, session['id'], fingerprint, 'admitted', timestamp()))
            self._append(session['id'], message)

    def state(self, identifier, state):
        with self.connection:
            self.connection.execute('UPDATE receipts SET state=? WHERE id=?', (state, identifier))

    def set_native(self, identifier, native_id):
        with self.connection:
            self.connection.execute('UPDATE sessions SET native_id=?, updated=? WHERE id=?',
                                    (native_id, timestamp(), identifier))

    def _append(self, identifier, message):
        payload = json.dumps(message, ensure_ascii=False)
        if len(payload.encode()) > 1024 * 1024:
            raise ValueError('Message exceeds storage limit')
        self.connection.execute('INSERT INTO messages(session_id,message_id,payload) VALUES(?,?,?) '
                                'ON CONFLICT(session_id,message_id) DO UPDATE SET payload=excluded.payload',
                                (identifier, message['id'], payload))
        self.connection.execute('UPDATE sessions SET updated=? WHERE id=?', (timestamp(), identifier))

    def append(self, identifier, message):
        with self.connection:
            self._append(identifier, message)

    def message_count(self, identifier):
        return self.connection.execute('SELECT count(*) FROM messages WHERE session_id=?',
                                       (identifier,)).fetchone()[0]

    def messages(self, identifier, limit, before=None):
        rows = self.connection.execute(
            'SELECT sequence,payload FROM messages WHERE session_id=? AND sequence<? '
            'ORDER BY sequence DESC LIMIT ?', (identifier, before or 2**63 - 1, limit + 1)).fetchall()
        selected = rows[:limit]
        return ([json.loads(row['payload']) for row in reversed(selected)],
                str(selected[-1]['sequence']) if len(rows) > limit else None)
