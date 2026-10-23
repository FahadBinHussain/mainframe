# Graphifyy on Linux: wheel available, restore still blocked

Graphifyy supports Linux; lack of a Linux release is not the blocker. The current declarations do not select an exact Graphifyy release or a Python interpreter, and there is no validated dependency lock or isolated uv-tool adapter. This review keeps installation blocked rather than manufacturing a reproducible install from incomplete inputs. No package artifact was downloaded, installed or executed.

## What the declarations actually say

The external offline recovery's `mainframe-quick.zip` recovered directory contains two control manifests declaring the string `graphifyy`: `uv-allowed.json` and `uv-tools.json`, with no version. These are external recovery evidence, not two tracked files in this checkout; `uv-tools.json` is not checked into the repository. The repository allowlist also uses that string. The Linux planner reads the allowlist, not `uv-tools.json`, and preserves the original unpinned proposal `uv tool install -- graphifyy` as a **blocked** action. It does not silently replace the declaration with today's latest release. Neither allowlists nor backup/export behavior are changed here.

## Published package and runtime evidence

The [versioned PyPI JSON](https://pypi.org/pypi/graphifyy/0.9.94/json) reports this observed release, not a selected restore version:

| Field | Published metadata |
|---|---|
| Name/version | `graphifyy` / `0.9.94` |
| Python requirement | `>=3.10` (no upper bound declared) |
| Wheel | `graphifyy-0.9.94-py3-none-any.whl` |
| Wheel size | 1,734,978 bytes |
| Wheel SHA-256 | `833322bb79ef720eb812dff0cb80f50b0b38f9cbbaa0446d546394a5dae75f27` |
| Wheel URL | `https://files.pythonhosted.org/packages/af/d6/7f8f6a9864774ae917d4515f6cc94639da2207a22aafefaa61923fad4f78/graphifyy-0.9.94-py3-none-any.whl` |

The wheel is non-yanked, platform-independent Python code, usable on Linux subject to Python and dependencies. PyPI also publishes an sdist; an ordinary unqualified install is not a wheels-only contract. The digest above is publisher/index metadata, not a locally verified artifact digest or independent signature.

The project's default branch was **`v8`**, not `main`, when queried. The observed [immutable packaging-source Git blob](https://api.github.com/repos/Graphify-Labs/graphify/git/blobs/ef5cc326d7f1e1276815bf11a36943d6fbceb504) agrees with published `0.9.94` and its dependency list. Floating branch URLs can change and are not release identities. The historical `main` branch reports `0.1.14` and different requirements; it must not be used as the current release manifest. The observed source declares `setuptools>=83.0.0` / `setuptools.build_meta` for source builds and entry points `graphify` and `graphify-mcp`. Source inspection did not execute either entry point or a build backend.

The base requirements are `networkx>=3.4`, `numpy>=1.21`, `rapidfuzz>=3.0`, conditional `tomli>=2.0.1` for Python <3.11, `tree-sitter>=0.25,<0.26`, and 25 tree-sitter grammar packages. All are ranges, not a complete exact hashed lock. Native dependencies require compatible implementation/ABI/architecture/libc wheel tags, independently of the root's `py3-none-any` tag.

Metadata-only inspection of the highest stable release in each base dependency range found Linux x86_64 or universal wheels for every inspected direct dependency. This is evidence that a wheels-only resolution is plausible, **not** proof of a compatible resolution or an inspected transitive lock. For example:

- [networkx 3.7](https://pypi.org/pypi/networkx/3.7/json) declares Python `!=3.14.1,>=3.12`.
- [numpy 2.5.4](https://pypi.org/pypi/numpy/2.5.4/json) declares Python `>=3.12`; inspected Linux x86_64 wheels use `manylinux_2_27` / `manylinux_2_28` tags.
- [rapidfuzz 3.14.6](https://pypi.org/pypi/rapidfuzz/3.14.6/json) declares Python `>=3.11`.
- [tree-sitter 0.25.2](https://pypi.org/pypi/tree-sitter/0.25.2/json) declares Python `>=3.10` and has CPython-specific Linux wheels through CPython 3.14 in the inspected release, but no CPython 3.15 wheel in that metadata.

A solver may choose older compatible dependencies for older Python versions. Taking every latest dependency is not a solver, and `>=3.10` is not a claim that all current dependency candidates support every newer Python. No exact Python version, provenance, executable path, ABI or host libc floor is selected by these declarations. No interpreter was probed to paper over that missing contract.

Extras are not requested by either declaration. In particular, do not infer `[all]` or `[dm]`: upstream notes that `tree-sitter-dm` needs source compilation on Linux. Default package installation is also distinct from the separately documented `graphify install` skill-registration command, which can write assistant profiles. Do not run registration, update-shell, self-updates, API probes or application commands as an installation test.

## What uv documents, and what a future adapter must enforce

The [uv environment reference](https://docs.astral.sh/uv/reference/environment/), [storage documentation](https://docs.astral.sh/uv/reference/storage/), [configuration rules](https://docs.astral.sh/uv/configuration/files/), and [tool-install CLI reference](https://docs.astral.sh/uv/reference/cli/#uv-tool-install) provide the necessary routing primitives, but setting just `UV_TOOL_DIR` is insufficient:

| Concern | Documented controls for a future plan |
|---|---|
| Tool environments | `UV_TOOL_DIR` |
| Exported executable links | `UV_TOOL_BIN_DIR` |
| Package cache | `UV_CACHE_DIR` / `--cache-dir` |
| User/system config discovery | `--no-config`, or a reviewed explicit `--config-file` / `UV_CONFIG_FILE` replacing discovered files; choose one policy, not conflicting flags |
| Managed Python installations | `UV_PYTHON_INSTALL_DIR` |
| Python executable links | `UV_PYTHON_BIN_DIR`; do not run `uv python update-shell` |
| Python archive cache | `UV_PYTHON_CACHE_DIR` |
| Interpreter choice | `--python /absolute/reviewed/interpreter`; a bare version request permits discovery/resolution and is not artifact provenance |
| Automatic runtime downloads | `--no-python-downloads` / `UV_PYTHON_DOWNLOADS=never` |
| Source builds | `--no-build` / `UV_NO_BUILD`; no editable, local, VCS or source requirements |
| Fallback user state and temporary files | Explicit child-only `HOME`, XDG config/cache/data/state roots and `TMPDIR`/`TMP`/`TEMP`; fresh environment rather than inherited uv/Python/index/auth settings |

For tool commands uv ignores local project config but normally reads user and system config. `--no-config` disables persistent discovery, not inherited environment variables. `--no-cache` uses a temporary directory; it does not by itself provide an isolated temporary destination. Do not invent a `--tool-dir` or `--tool-bin-dir` CLI switch: these destinations use documented environment variables.

Before any future detailed plan is accepted, **missing roots must raise an error**, and all roots must be explicit canonical absolute paths, distinct and non-overlapping. Reject relative paths, traversal, existing destination state, symlinks/aliases and symlink parents, overlap with the live home/repository/recovered source/system paths, and runtime/cache/bin/config nesting. Define the interpreter's reviewed relationship to its Python runtime root explicitly. No defaults under `$HOME`, no parent environment/PATH edits and no directory creation are justified by a dry plan. Recheck publication safely before any later authorized write; path validation alone does not prevent races.

A future implementation must version-check the uv option contract, select a verified exact interpreter and uv artifact, evaluate Python markers, choose compatible wheels for the complete dependency graph, record exact versions/URLs/hashes, and fail rather than fall back to an sdist or automatic Python download. `--no-build` rejects required source builds (and can reuse cached previously built wheels); it is not a replacement for a reviewed fresh cache and complete artifact provenance. Wheels avoid their source build backend, but do not prove runtime safety or the absence of executable `.pth`/import side effects. uv can invoke Python for interpreter/environment handling; routing variables are not an OS security sandbox or a guarantee against arbitrary package behavior.

## Decision and regression boundary

No generic uv adapter or root-config CLI is introduced in this change: without an exact runtime and complete wheel resolution it would only emit an unvalidated recipe. Therefore there is no successful roots-preflight result to imply; missing or overlapping roots never enable installation. The planner explains each missing prerequisite and keeps both pinned and unpinned uv declarations blocked. A version field alone cannot bypass runtime/dependency/isolation review.

Offline regression tests preserve the original declaration/command, require a precise unpinned warning only when applicable, and prove blocked and forged-planned uv selections cannot invoke the runner or cause an earlier APT action to execute. No runtime, package download, hook execution, home/profile mutation, terms acceptance or credentials are needed by these tests.
