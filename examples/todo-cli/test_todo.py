"""Tests for todo.py. Each test names the requirement it proves (see
specs/todo/requirements.md), so the requirement gate can find it."""
import contextlib
import io
import os
import tempfile
import unittest

import todo


class TodoTest(unittest.TestCase):
    def run_cli(self, *argv):
        """Run the command line the way a user would; return (exit code, output)."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = todo.main(list(argv))
        return code, out.getvalue()

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        os.environ["TODO_FILE"] = os.path.join(self.dir.name, "todos.json")

    def tearDown(self):
        os.environ.pop("TODO_FILE", None)
        self.dir.cleanup()

    def test_add_saves_an_open_todo(self):
        # REQ-TODO-001
        item = todo.add("buy milk")
        self.assertEqual(item, {"id": 1, "title": "buy milk", "done": False})
        self.assertEqual(todo.load(), [item])

    def test_list_shows_every_todo_in_order(self):
        # REQ-TODO-002
        todo.add("buy milk")
        todo.add("call mum")
        self.assertEqual(todo.render(todo.load()), "1. [ ] buy milk\n2. [ ] call mum")

    def test_done_marks_the_todo_finished(self):
        # REQ-TODO-003
        todo.add("buy milk")
        todo.done(1)
        self.assertEqual(todo.render(todo.load()), "1. [x] buy milk")

    def test_done_on_an_unknown_id_is_an_error(self):
        # REQ-TODO-003
        with self.assertRaises(KeyError):
            todo.done(7)

    def test_add_command_saves_the_todo(self):
        # REQ-TODO-001
        self.assertEqual(self.run_cli("add", "buy", "milk"), (0, "added 1\n"))
        self.assertEqual(todo.load(), [{"id": 1, "title": "buy milk", "done": False}])

    def test_list_command_prints_every_todo(self):
        # REQ-TODO-002
        self.run_cli("add", "buy milk")
        self.run_cli("add", "call mum")
        code, output = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertEqual(output, "1. [ ] buy milk\n2. [ ] call mum\n")

    def test_done_command_marks_the_todo_finished(self):
        # REQ-TODO-003
        self.run_cli("add", "buy milk")
        self.assertEqual(self.run_cli("done", "1"), (0, "done 1\n"))
        self.assertEqual(self.run_cli("list")[1], "1. [x] buy milk\n")


if __name__ == "__main__":
    unittest.main()
