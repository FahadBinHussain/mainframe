#pragma once
#include <memory>
#include <string>
#include <vector>

namespace wacli::vss {
struct ResolvedRoot { std::string source_root; std::string volume_guid; };
struct SnapshotInfo { std::string snapshot_id; std::string volume_guid; };
enum class AsyncState { pending, finished, cancelled, failed };
struct CleanupResult {
    bool complete = false;
    std::size_t deleted = 0;
    std::string error;
};
class VolumeResolver {
public:
    virtual ~VolumeResolver() = default;
    virtual bool resolve(const std::string&, ResolvedRoot&, std::string&) = 0;
};
// Single-use backend, on one COM-initialized thread. Errors contain fixed
// diagnostics, never source paths or other private source metadata.
class Backend {
public:
    virtual ~Backend() = default;
    virtual bool initialize(std::string&) = 0;
    virtual bool set_writerless_backup_context(std::string&) = 0;
    virtual bool start_snapshot_set(std::string&, std::string&) = 0;
    virtual bool add_to_snapshot_set(const std::string&, std::string&, std::string&) = 0;
    virtual bool do_snapshot_set(std::string&) = 0;
    // One status observation; pending may pause briefly, never wait indefinitely.
    virtual AsyncState query_status(std::string&) = 0;
    virtual bool verify_snapshot_set(const std::vector<SnapshotInfo>&, std::string&) = 0;
    // Available only while this single-use requester owns the verified set.
    virtual bool snapshot_device(const SnapshotInfo&, std::string&, std::string& error) {
        error = "snapshot device unavailable"; return false;
    }
    // Called once explicitly and as a destructor backstop if explicit cleanup was
    // not reached. Cancels/observes pending async, then deletes the WHOLE set.
    virtual CleanupResult cleanup(bool snapshot_finished, std::size_t expected) noexcept = 0;
};
// Internal development seam, not an application consistency authorization.
// Stage inventories every explicit root from shadows, then copies only shadow
// bytes to newly-created private storage. verify runs with the set held.
class SnapshotCopy {
public:
    virtual ~SnapshotCopy() = default;
    virtual bool stage(const std::vector<ResolvedRoot>&, const std::vector<SnapshotInfo>&,
                       Backend&, std::string&) = 0;
    virtual bool verify(std::string&) = 0;
    virtual bool discard(std::string&) noexcept = 0;
    virtual std::string staging_directory() const { return {}; }
    // Export only a successful verified stage; implementations must fail on
    // any omitted member and must never reopen the live source roots.
    virtual bool export_verified(const std::string&, std::string& error) {
        error = "verified export unavailable"; return false;
    }
};
struct Result {
    bool ok = false;
    bool capture_enabled = false;
    bool windows_validated = false;
    bool shadows_released = false;
    bool staged_verified = false;
    bool staging_discarded = false;
    std::string staging_directory;
    std::string error;
    std::string staging_cleanup_error;
    CleanupResult cleanup;
    std::vector<ResolvedRoot> mappings;
    // Private diagnostic IDs only. Never usable held shadows after return.
    std::string set_id;
    std::vector<SnapshotInfo> snapshots;
};
bool canonical_volume(const std::string&);
// Development probe only: snapshots are deleted before return; no copy callback,
// archive, capture receipt, application-consistency guarantee or public CLI.
Result probe_volumes(const std::vector<std::string>&, VolumeResolver&, Backend&);
// Internal Windows backup helper may export these bytes; this is not a WACLI
// application-consistency claim or restore-activation authorization.
Result stage_snapshot_roots(const std::vector<std::string>&, VolumeResolver&, Backend&, SnapshotCopy&);
#ifdef _WIN32
std::unique_ptr<VolumeResolver> make_native_resolver();
std::unique_ptr<Backend> make_native_backend();
std::unique_ptr<SnapshotCopy> make_native_snapshot_copy(const std::string& private_parent);
#endif
}
