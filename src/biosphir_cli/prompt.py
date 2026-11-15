"""PowerShell-style input colors and tokenization for the Bicdop prompt."""

import io
import re
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Callable

from prompt_toolkit.application import Application, run_in_terminal
from prompt_toolkit.data_structures import Point
from prompt_toolkit.formatted_text import ANSI
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.layout import FormattedTextControl, HSplit, Layout, ScrollbarMargin, Window
from prompt_toolkit.widgets import TextArea
from prompt_toolkit.lexers import Lexer
from prompt_toolkit.styles import Style

from .folders import is_folder_path

TOKENS = re.compile(r'''"[^"]*"?|'[^']*'?|[^\s,"']+|,|\s+''')


class CommandLexer(Lexer):
    def lex_document(self, document):
        def line_tokens(line_number):
            tokens = TOKENS.findall(document.lines[line_number])
            return [
                (
                    "class:string" if token.startswith(('"', "'"))
                    else "class:parameter" if token.startswith("-")
                    else "class:command" if index == 0
                    else "",
                    token,
                )
                for index, token in enumerate(tokens)
            ]
        return line_tokens


class CommandOutput(io.StringIO):
    def __init__(self, terminal=None):
        super().__init__()
        self.terminal = terminal

    def isatty(self) -> bool:
        return sys.__stdout__ is not None and sys.__stdout__.isatty()

    def write(self, text: str) -> int:
        if self.terminal is not None:
            self.terminal.write(text)
            self.terminal.flush()
        return super().write(text)


def show_interface(header: Callable[[], str], execute: Callable[[list[str]], bool | None]) -> None:
    history: list[str] = []
    busy = False
    bindings = KeyBindings()
    output = Window(
        FormattedTextControl(
            lambda: ANSI("\n".join(history)),
            # Keep the hidden cursor in the viewport so redraws preserve scrolling.
            get_cursor_position=lambda: Point(x=0, y=min(output.vertical_scroll, max(0, len(history) - 1))),
        ),
        right_margins=[ScrollbarMargin(display_arrows=True)],
        wrap_lines=False,
        always_hide_cursor=True,
    )

    def scroll(delta: int) -> None:
        rows = output.render_info.window_height if output.render_info else 1
        bottom = max(0, len(history) - rows)
        output.vertical_scroll = min(bottom, max(0, output.vertical_scroll + delta))

    def invoke(arguments: list[str], visible: bool) -> bool | None:
        capture = CommandOutput(sys.stdout if visible else None)
        try:
            with redirect_stdout(capture), redirect_stderr(capture):
                try:
                    return execute(arguments)
                except (SystemExit, KeyboardInterrupt):
                    return None
                except ValueError as exc:
                    print(exc, file=sys.stderr)
        finally:
            history.extend(capture.getvalue().splitlines())

    async def submit(line: str) -> None:
        nonlocal busy
        try:
            if line.lower() in {"exit", "quit"}:
                application.exit()
                return
            history.append(f"> {line}")
            try:
                arguments = command_tokens(line)
            except ValueError as exc:
                history.append(str(exc))
                return
            # Confirmation input and the updater can use the normal console.
            visible = any(option in arguments for option in ("--delete", "--collect", "--update", "--set-github", "--push", "--pull"))
            result = await run_in_terminal(lambda: invoke(arguments, True)) if visible else invoke(arguments, False)
            if result:
                application.exit()
        finally:
            busy = False
            scroll(len(history))
            application.invalidate()

    def accept(buffer) -> bool:
        nonlocal busy
        line = buffer.text.strip()
        if line and not busy:
            busy = True
            application.create_background_task(submit(line))
        return False

    @bindings.add("pageup")
    def page_up(event) -> None:
        scroll(-(output.render_info.window_height if output.render_info else 1))

    @bindings.add("pagedown")
    def page_down(event) -> None:
        scroll(output.render_info.window_height if output.render_info else 1)

    @bindings.add("c-d")
    def exit_prompt(event) -> None:
        if not busy and not field.text:
            event.app.exit()

    field = TextArea(
        height=1,
        multiline=False,
        prompt=lambda: f"bicdop [{Path.cwd()}]> ",
        lexer=CommandLexer(),
        accept_handler=accept,
    )
    layout = HSplit([
        Window(FormattedTextControl(header), height=5, wrap_lines=False, style="class:header"),
        output,
        field,
    ])
    application = Application(
        layout=Layout(layout, focused_element=field),
        key_bindings=bindings,
        full_screen=True,
        mouse_support=True,
        style=Style.from_dict({
            "header": "bold ansicyan",
            "string": "ansicyan",
            "parameter": "ansibrightblack",
            "command": "ansiyellow",
        }),
    )
    application.run()


def command_tokens(line: str) -> list[str]:
    arguments = []
    for token in TOKENS.findall(line):
        if token.isspace():
            continue
        if token.startswith(('"', "'")):
            if len(token) < 2 or token[-1] != token[0]:
                raise ValueError("Close the quoted value before submitting the command.")
            arguments.append(token[1:-1])
        else:
            if is_folder_path(token):
                raise ValueError("Put folder paths in quotes.")
            arguments.append(token)
    return arguments
