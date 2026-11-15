"""PowerShell-style input colors and tokenization for the Bicdop prompt."""

import re

from prompt_toolkit import PromptSession
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


def prompt_session() -> PromptSession:
    style = Style.from_dict({"string": "ansicyan", "parameter": "ansibrightblack", "command": "ansiyellow"})
    return PromptSession(lexer=CommandLexer(), style=style)


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
