"""A tiny to-do list kept in a JSON file.

    python3.12 todo.py add "buy milk"
    python3.12 todo.py list
    python3.12 todo.py done 1

The file is todos.json in the current folder, or the path in $TODO_FILE.
"""
import json
import os
import sys


def path():
    return os.environ.get("TODO_FILE", "todos.json")


def load():
    if not os.path.exists(path()):
        return []
    with open(path(), encoding="utf-8") as f:
        return json.load(f)


def save(todos):
    with open(path(), "w", encoding="utf-8") as f:
        json.dump(todos, f, indent=2)


def add(title):
    todos = load()
    todos.append({"id": len(todos) + 1, "title": title, "done": False})
    save(todos)
    return todos[-1]


def done(todo_id):
    todos = load()
    for todo in todos:
        if todo["id"] == todo_id:
            todo["done"] = True
            save(todos)
            return todo
    raise KeyError(f"no to-do with id {todo_id}")


def render(todos):
    return "\n".join(f"{t['id']}. [{'x' if t['done'] else ' '}] {t['title']}" for t in todos)


def main(argv):
    if len(argv) >= 2 and argv[0] == "add":
        print(f"added {add(' '.join(argv[1:]))['id']}")
    elif argv == ["list"]:
        print(render(load()) or "nothing to do")
    elif len(argv) == 2 and argv[0] == "done":
        print(f"done {done(int(argv[1]))['id']}")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
