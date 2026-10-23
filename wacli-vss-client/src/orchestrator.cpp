#include "vss_client.h"
#include <cctype>
#include <set>
#include <stdexcept>

namespace wacli::vss {
bool canonical_volume(const std::string& s) {
    // Canonical internal spelling: lowercase \\?\volume{GUID}\.
    if (s.size() != 49 || s.compare(0, 11, "\\\\?\\volume{") != 0 ||
        s.substr(47) != "}\\") return false;
    for (std::size_t i = 11; i < 47; ++i) {
        if (i == 19 || i == 24 || i == 29 || i == 34) {
            if (s[i] != '-') return false;
        } else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) {
            return false;
        }
    }
    return true;
}

namespace {
Result transact(const std::vector<std::string>& roots, VolumeResolver& resolver, Backend& backend,
                SnapshotCopy* copy) {
    Result result;
    bool started = false;
    bool finished = false;
    bool copy_attempted = false;
    bool copy_verified = false;
    auto discard = [&]() {
        if (!copy_attempted) return;
        copy_attempted = false;
        std::string ignored;
        result.staging_discarded = copy->discard(ignored);
        result.staged_verified = false;
        result.staging_directory.clear();
        if (!result.staging_discarded) {
            result.staging_cleanup_error = "private staging cleanup incomplete";
            if (result.error.empty()) result.error = result.staging_cleanup_error;
        }
    };
    // Backstop also covers allocations/exceptions after StartSnapshotSet.
    struct Owner {
        Backend& backend;
        Result& result;
        bool& started;
        bool& finished;
        void release() noexcept {
            if (!started) return;
            started = false;
            result.cleanup = backend.cleanup(finished, result.snapshots.size());
            result.shadows_released = result.cleanup.complete;
        }
        ~Owner() { release(); }
    } owner{backend, result, started, finished};
    try {
        if (roots.empty() || roots.size() > 4096) {
            result.error = "approved root count outside development limit";
            return result;
        }
        std::set<std::string> volumes;
        for (const auto& root : roots) {
            ResolvedRoot resolved;
            if (!resolver.resolve(root, resolved, result.error)) {
                if (result.error.empty()) result.error = "source root unsupported";
                return result;
            }
            if (resolved.source_root != root || !canonical_volume(resolved.volume_guid)) {
                result.error = "invalid canonical source membership";
                return result;
            }
            result.mappings.push_back(resolved);
            volumes.insert(resolved.volume_guid);
            if (volumes.size() > 64) {
                result.error = "more than 64 required volumes";
                return result;
            }
        }
        if (!backend.initialize(result.error) || !backend.set_writerless_backup_context(result.error)) {
            if (result.error.empty()) result.error = "requester initialization failed";
            return result;
        }
        if (!backend.start_snapshot_set(result.set_id, result.error)) {
            // Backend owns cleanup if Start succeeds but ID conversion fails.
            if (result.error.empty()) result.error = "snapshot set start failed";
            return result;
        }
        started = true;
        if (result.set_id.empty()) throw std::runtime_error("empty set ID");
        for (const auto& volume : volumes) {
            SnapshotInfo snapshot;
            snapshot.volume_guid = volume;
            if (!backend.add_to_snapshot_set(volume, snapshot.snapshot_id, result.error) ||
                snapshot.snapshot_id.empty()) {
                if (result.error.empty()) result.error = "snapshot volume addition failed";
                owner.release();
                return result;
            }
            result.snapshots.push_back(snapshot);
        }
        if (!backend.do_snapshot_set(result.error)) {
            if (result.error.empty()) result.error = "snapshot creation failed";
        } else {
            for (unsigned i = 0; i < 600; ++i) {
                const auto state = backend.query_status(result.error);
                if (state == AsyncState::finished) { finished = true; break; }
                if (state == AsyncState::cancelled) {
                    result.error = "snapshot creation cancelled";
                    break;
                }
                if (state == AsyncState::failed) {
                    if (result.error.empty()) result.error = "snapshot async failure";
                    break;
                }
            }
            if (!finished && result.error.empty()) result.error = "snapshot creation timeout";
            if (finished && !backend.verify_snapshot_set(result.snapshots, result.error) && result.error.empty())
                result.error = "snapshot membership verification failed";
            if (finished && result.error.empty() && copy) {
                copy_attempted = true; // Includes a stage that throws or fails halfway.
                if (!copy->stage(result.mappings, result.snapshots, backend, result.error)) {
                    if (result.error.empty()) result.error = "snapshot inventory or copy failed";
                } else if (result.error.empty() && !copy->verify(result.error)) {
                    if (result.error.empty()) result.error = "staged byte verification failed";
                }
                if (result.error.empty() && !backend.verify_snapshot_set(result.snapshots, result.error))
                    result.error = "held snapshot membership verification failed";
                if (result.error.empty()) {
                    result.staging_directory = copy->staging_directory();
                    if (result.staging_directory.empty()) result.error = "private staging identity missing";
                    else copy_verified = true;
                }
            }
        }
        if (!result.error.empty()) discard();
        owner.release();
        if (!result.cleanup.complete && result.error.empty()) result.error = "snapshot cleanup incomplete";
        result.ok = finished && result.error.empty() && result.cleanup.complete && (!copy || copy_verified);
        if (!result.ok) discard();
        result.staged_verified = result.ok && copy_verified;
    } catch (...) {
        result.error = "development snapshot transaction exception";
        discard();
        owner.release();
    }
    return result;
}
}

Result probe_volumes(const std::vector<std::string>& roots, VolumeResolver& resolver, Backend& backend) {
    return transact(roots, resolver, backend, nullptr);
}
Result stage_snapshot_roots(const std::vector<std::string>& roots, VolumeResolver& resolver,
                            Backend& backend, SnapshotCopy& copy) {
    return transact(roots, resolver, backend, &copy);
}
}
