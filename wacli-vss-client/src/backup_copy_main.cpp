#include "vss_client.h"

#ifdef _WIN32
#include <iostream>
#include <string>
#include <utility>
#include <vector>
#include <windows.h>

namespace {
bool utf8(const std::wstring &value, std::string &output) {
    if (value.empty()) return false;
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                         static_cast<int>(value.size()), nullptr, 0,
                                         nullptr, nullptr);
    if (size <= 0) return false;
    output.assign(static_cast<size_t>(size), '\0');
    return WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                               static_cast<int>(value.size()), output.data(), size,
                               nullptr, nullptr) == size;
}
}

int wmain(int argc, wchar_t **argv) {
    std::string parent;
    std::string destination;
    std::vector<std::string> roots;
    for (int i = 1; i < argc; ++i) {
        const std::wstring option(argv[i]);
        if ((option == L"--parent" || option == L"--destination" || option == L"--root") &&
            i + 1 < argc) {
            std::string value;
            if (!utf8(argv[++i], value)) {
                std::cerr << "Invalid UTF-16 command argument.\n";
                return 2;
            }
            if (option == L"--parent") {
                if (!parent.empty()) { std::cerr << "Duplicate private parent.\n"; return 2; }
                parent = std::move(value);
            } else if (option == L"--destination") {
                if (!destination.empty()) { std::cerr << "Duplicate destination.\n"; return 2; }
                destination = std::move(value);
            } else {
                roots.push_back(std::move(value));
            }
        } else {
            std::cerr << "Usage: wacli_vss_backup --parent DIR --destination DIR --root DIR [--root DIR ...]\n";
            return 2;
        }
    }
    if (parent.empty() || destination.empty() || roots.empty()) {
        std::cerr << "A private parent, a new destination, and at least one root are required.\n";
        return 2;
    }

    std::unique_ptr<wacli::vss::SnapshotCopy> copy;
    try {
        auto resolver = wacli::vss::make_native_resolver();
        auto backend = wacli::vss::make_native_backend();
        copy = wacli::vss::make_native_snapshot_copy(parent);
        if (!resolver || !backend || !copy) {
            std::cerr << "Native VSS components unavailable.\n";
            return 3;
        }
        // All roots are passed together. The orchestrator resolves every volume,
        // creates one fixed-membership set, copies shadow bytes, verifies them,
        // and releases the whole set before this export step.
        const auto result = wacli::vss::stage_snapshot_roots(roots, *resolver, *backend, *copy);
        if (!result.ok || !result.staged_verified || !result.shadows_released) {
            std::cerr << "Held-VSS transaction failed: "
                      << (result.error.empty() ? "staged copy was not verified" : result.error)
                      << "\n";
            return 4;
        }
        std::string error;
        if (!copy->export_verified(destination, error)) {
            std::cerr << "Verified VSS export failed: "
                      << (error.empty() ? "destination copy incomplete" : error) << "\n";
            std::string cleanup_error;
            if (!copy->discard(cleanup_error)) {
                std::cerr << "Private staging cleanup failed: "
                          << (cleanup_error.empty() ? "cleanup incomplete" : cleanup_error) << "\n";
            }
            return 5;
        }
        if (!copy->discard(error)) {
            std::cerr << "Private staging cleanup failed: "
                      << (error.empty() ? "cleanup incomplete" : error) << "\n";
            return 6;
        }
        return 0;
    } catch (...) {
        if (copy) {
            std::string cleanup_error;
            if (!copy->discard(cleanup_error)) {
                std::cerr << "Private staging cleanup failed: "
                          << (cleanup_error.empty() ? "cleanup incomplete" : cleanup_error) << "\n";
            }
        }
        std::cerr << "Held-VSS backup helper failed unexpectedly.\n";
        return 6;
    }
}
#endif
