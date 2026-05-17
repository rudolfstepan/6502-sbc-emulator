# MS BASIC Text Converter

`tools/basic_convert.py` converts between tokenized BASIC `.prg` files and editable text.

## Usage

Detokenize PRG to text:

```sh
python3 tools/basic_convert.py data/disk/basic.prg program.txt
```

Tokenize text to PRG:

```sh
python3 tools/basic_convert.py program.txt data/disk/basic.prg
```

## Typical Workflow

1. Write or save a BASIC program into `data/disk/basic.prg`.
2. Convert to text for editing.
3. Convert back to `.prg`.
4. Start emulator and `LOAD` in BASIC.

## Text Format

- one BASIC line per text line
- format: `<line-number> <statement>`
- empty lines ignored
- lines starting with `#` ignored

## Notes

- Supports MS BASIC V2 token set used by this project.
- Intended for practical edit/export loops, not for preserving exact original binary layout.
