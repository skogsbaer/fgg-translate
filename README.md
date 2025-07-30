# READ-ONLY

This repository has been moved to https://github.com/go-collaboration/fgg-translate

# Translating Go

This Haskell project implements translations from Featherweight (Generic)
Go to various target languages.

* There is a syntax-directed translation from FG to Haskell.
* There is a type-directed translation from FGG to Racket (untyped target
  language).

## Usage

This project assumes that you use the [stack tool](https://docs.haskellstack.org/en/stable/README/)
for compiling and running the translation. (Using cabal should be possible but was not tested.)

* Compile: `stack build`
* Test: `stack test`
* Install: `stack install`
* Run without installation:
  * `stack run -- FILE.go`
  * Or use the script `./gotrans FILE.go` in the toplevel directory
    (requires bash and some sort of unix system)
* Run with installation: `gotrans FILE.go` (make sure stack's installation
  directory is in your path)

Running the translation for input file `FILE.go` produces either the Haskell file
`FILE.hs` or the racket file `FILE.rkt`.
Load the Haskell file into ghci, for example via
`stack exec ghci -- FILE.hs`, and then invoke the main function by typing `main`
at the ghci prompt. Just run the racket file via `racket FILE.rkt`.

### Important list of commandline options

* To use the same syntax for generics as Go, use the `--modern` commandline
  switch. Type arguments are then put in square brackets `[...]`.
* Type-directed translation to Racket: `--type` (without generics) or `--type-generic`.
* Syntax-directed transaltion to Haskell (no support for generics): `--syntax`

### Full list of commandline options:

```
Usage: gotrans [--target ARG] [--no-casts] [--trace] FILE [--modern]
  Translations from Featherweight (Generic) Go to various target languages

Available options:
  --target ARG             The target ('parse', 'parse-generic', 'syntax', 'type', 'type-generic')
  --no-casts               Do not translate casts
  --trace                  Enable tracing
  --modern                 Use modern syntax for generics
  -h,--help                Show this help text
```

## Source Language

The source language is Featherweight Go with the following additions:

- Support for builtin types int, char, bool, and string.
- Support for type definitions
- Import of "fmt" is allowed.
- The main function may declare a sequence of variables and than
  perform a fmt.Printf
- There might be several "main" functions, named `main`, `main0`, `main1`,
  `main2` and so on.
- The translation accepts pragmas of the form
  `//#import FILE.go` for literally including all declarations in FILE.go

## Target language: Haskell

The output of the syntax-directed translation in Haskell with several language extension
as accepted by GHC. The language extension are included as pragmas
in the output.


## Papers

Martin Sulzmann and Stefan Wehr
Semantic preservation for a type directed translation scheme of Featherweight Go
In Proc. of MPC 2022. Lecture Notes in Computer Science, vol. ?, Chicago, IL, USA. SPRINGER, 2022.
[arxiv](https://arxiv.org/abs/2206.09980)

Martin Sulzmann and Stefan Wehr
A Dictionary-Passing Translation of Featherweight Go
In Proc. of APLAS 2021. Lecture Notes in Computer Science, vol. 13008,
Chicago, IL, USA. SPRINGER, 2021.
[arxiv](https://arxiv.org/abs/2106.14586)
