# Python restore: Windows API dependency remains blocked

The reviewed declaration is **`pywin32-ctypes==0.2.3`**, with no environment marker. Keep the whole Python environment rebuild explicitly blocked. The backup manifest is not edited, filtered, copied into a derived install manifest, or replaced. No package is dropped, no substitute is selected, and no installation, build or runtime probe is enabled.

## Why a universal wheel is not a Linux port

The official [PyPI metadata for 0.2.3](https://pypi.org/pypi/pywin32-ctypes/0.2.3/json) describes a partial reimplementation of pywin32 using ctypes/cffi, requires Python >=3.6, and publishes a `py3-none-any` wheel. Pure Python and an `any` distribution tag do not supply the operating-system APIs that its functions call.

The exact [v0.2.3 README](https://raw.githubusercontent.com/enthought/pywin32-ctypes/v0.2.3/README.rst) says Unix development/testing uses **Wine**. Its [ctypes utility backend](https://raw.githubusercontent.com/enthought/pywin32-ctypes/v0.2.3/win32ctypes/core/ctypes/_util.py) imports `WinDLL` and loads Windows DLLs. Its [credential bindings](https://raw.githubusercontent.com/enthought/pywin32-ctypes/v0.2.3/win32ctypes/core/ctypes/_authentication.py) call `advapi32` functions such as `CredReadW` and `CredWriteW`. No native Linux implementation of those functions is documented. Wine would be a separately scoped Windows compatibility runtime, not the native Linux same-library route requested here.

## Why a marker is not the fix

An environment marker such as `sys_platform == "win32"` preserves the Windows declaration but excludes it on Linux. [Python dependency specifiers](https://packaging.python.org/en/latest/specifications/dependency-specifiers/) explicitly define a false marker as an ignored dependency. That can be appropriate for a project whose Linux backend and conditional dependency use are already established; this freeze declaration alone does not establish either.

Here, exclusion would remove the Windows functionality, not reproduce it. There is no approved exclusion, replacement or demonstrated same-library Linux backend, so the planner must not create a filtered requirements file or mark the Python rebuild successful. Owner-approved behavior changes would be a separate task. Interpreter provenance/ABI, complete dependency compatibility and integrity, and explicit isolated environment/cache/config destinations would still need review even after any approved platform decision.

## Guard and evidence boundaries

The planner normalizes project-name case and `-`, `_`, `.` spellings for its existing Windows dependency guard and adds an explicit pywin32-ctypes explanation. It does not evaluate markers as permission to discard declarations. It reports neither raw requirement lines nor private URLs/index values. Existing Windows wheel/path detection and the default Python execution block remain in place.

Offline tests use synthetic manifests to prove byte-for-byte preservation, no derived/filter output, retention of the blocked manifest action, rejection before any selected APT/Python command, normalized-name handling, and no private requirement values in diagnostics. These are guard tests, not evidence that other Python packages can be rebuilt. Other package blockers are outside this review.
