# Requirements — todo

<!-- Written in the framework's format (templates/specs/requirements.md):
     a permanent ID, one EARS sentence, and how it is verified. -->

REQ-TODO-001  WHEN a user runs `todo.py add <title>`, THE SYSTEM SHALL save a
              new, not-done to-do with the next id and that title.
              verify: unit

REQ-TODO-002  WHEN a user runs `todo.py list`, THE SYSTEM SHALL show every
              to-do in the order it was added, with its id and a done mark.
              verify: unit

REQ-TODO-003  WHEN a user runs `todo.py done <id>`, THE SYSTEM SHALL mark that
              to-do done, and SHALL report an error for an id that does not exist.
              verify: unit
