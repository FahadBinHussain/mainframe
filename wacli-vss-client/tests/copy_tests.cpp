#include "vss_client.h"
#include <algorithm>
#include <cstdio>
#include <map>
#include <stdexcept>
using namespace wacli::vss;
namespace {
void check(bool value) { if (!value) throw std::runtime_error("held-copy synthetic assertion failed"); }
std::string volume(char c) { return std::string("\\\\?\\volume{") + c + "0000000-0000-0000-0000-000000000000}\\"; }
struct World {
    std::vector<std::string> events;
    bool frozen = false, released = false;
    std::map<std::string, std::string> shadows, live, staged;
    World() {
        shadows = {{"shadow1/store/session.db", std::string("\0\xff\r\n", 4)},
                   {"shadow1/store/session.db-wal", "WAL"},
                   {"shadow1/store/session.db-shm", "SHM"},
                   {"shadow2/media/blob", std::string(200000, '\x80')},
                   {"shadow2/media/empty", ""}};
        live = shadows;
    }
};
struct Resolver final : VolumeResolver {
    World& w;
    explicit Resolver(World& world) : w(world) {}
    bool resolve(const std::string& root, ResolvedRoot& out, std::string&) override {
        check(!w.frozen); // No live source inspection after DoSnapshotSet.
        w.events.push_back("resolve");
        if (root != "C:\\store" && root != "D:\\media") return false;
        out = {root, volume(root[0] == 'C' ? '1' : '2')}; return true;
    }
};
struct BackendDouble final : Backend {
    World& w;
    std::string fail;
    unsigned starts = 0, dos = 0, cleanups = 0, verifies = 0;
    std::vector<std::string> volumes;
    explicit BackendDouble(World& world) : w(world) {}
    bool step(const std::string& value) {
        w.events.push_back(value); return fail != value;
    }
    bool initialize(std::string&) override { return step("initialize"); }
    bool set_writerless_backup_context(std::string&) override { return step("context"); }
    bool start_snapshot_set(std::string& id, std::string&) override { ++starts; id = "one-set"; return step("start"); }
    bool add_to_snapshot_set(const std::string& vol, std::string& id, std::string&) override {
        check(!w.frozen); volumes.push_back(vol); id = vol; return step("add");
    }
    bool do_snapshot_set(std::string&) override {
        ++dos; check(volumes.size() == 2); w.frozen = true;
        // Subsequent live mutations cannot affect the frozen inventory/bytes.
        w.live.clear(); w.live["live-only"] = "must never be read";
        return step("do");
    }
    AsyncState query_status(std::string&) override { return step("query") ? AsyncState::finished : AsyncState::failed; }
    bool verify_snapshot_set(const std::vector<SnapshotInfo>& s, std::string&) override {
        check(w.frozen && !w.released && s.size() == 2); ++verifies;
        return step(verifies == 1 ? "membership" : "membership-after-copy");
    }
    bool snapshot_device(const SnapshotInfo& s, std::string& device, std::string&) override {
        check(w.frozen && !w.released && verifies > 0);
        device = s.volume_guid == volume('1') ? "shadow1" : "shadow2";
        return step("device");
    }
    CleanupResult cleanup(bool finished, std::size_t expected) noexcept override {
        ++cleanups; w.released = true;
        return {fail != "cleanup", finished ? expected : 0, ""};
    }
};
struct CopyDouble final : SnapshotCopy {
    World& w;
    std::string fail;
    bool throws = false, corrupt = false, extra = false, discard_fails = false;
    unsigned stages = 0, verifies = 0, discards = 0;
    explicit CopyDouble(World& world) : w(world) {}
    bool step(const std::string& value) {
        check(w.frozen && !w.released);
        w.events.push_back(value);
        if (fail == value && throws) throw std::runtime_error("injected private detail");
        return fail != value;
    }
    bool stage(const std::vector<ResolvedRoot>& roots, const std::vector<SnapshotInfo>& snapshots,
               Backend& backend, std::string& error) override {
        ++stages; check(roots.size() == 2 && snapshots.size() == 2);
        if (!step("inventory")) return false;
        std::vector<std::string> inventory;
        for (const auto& root : roots) {
            auto member = std::find_if(snapshots.begin(), snapshots.end(), [&](const SnapshotInfo& s) {
                return s.volume_guid == root.volume_guid;
            });
            check(member != snapshots.end());
            std::string device;
            if (!backend.snapshot_device(*member, device, error)) return false;
            const auto prefix = device + (root.source_root[0] == 'C' ? "/store/" : "/media/");
            for (const auto& entry : w.shadows)
                if (entry.first.compare(0, prefix.size(), prefix) == 0) inventory.push_back(entry.first);
        }
        check(inventory.size() == w.shadows.size());
        for (const auto& file : inventory) {
            if (!step("read")) return false;
            auto bytes = w.shadows.at(file);
            if (!step("write")) return false;
            w.staged.emplace(file, bytes);
        }
        if (corrupt) w.staged.begin()->second += "changed";
        if (extra) w.staged["unexpected"] = "extra";
        return true;
    }
    bool verify(std::string&) override {
        ++verifies;
        return step("byte-verify") && w.shadows == w.staged;
    }
    bool discard(std::string&) noexcept override {
        ++discards;
        if (discard_fails) return false;
        w.staged.clear(); return true;
    }
    std::string staging_directory() const override { return fail == "identity" ? "" : "synthetic-private-stage"; }
};
const std::vector<std::string> roots{"C:\\store", "D:\\media"};
void success() {
    World w; Resolver r(w); BackendDouble b(w); CopyDouble c(w);
    const auto result = stage_snapshot_roots(roots, r, b, c);
    check(result.ok && result.staged_verified && result.shadows_released && !result.staging_discarded);
    check(!result.capture_enabled && !result.windows_validated && !result.staging_directory.empty());
    check(b.starts == 1 && b.dos == 1 && b.cleanups == 1 && b.verifies == 2);
    check(c.stages == 1 && c.verifies == 1 && c.discards == 0);
    check(w.staged == w.shadows && w.staged != w.live && w.released);
    const auto index = [&](const std::string& event) {
        return std::find(w.events.begin(), w.events.end(), event) - w.events.begin();
    };
    check(index("do") < index("query") && index("query") < index("membership"));
    check(index("membership") < index("inventory") && index("inventory") < index("read"));
    check(index("read") < index("byte-verify") && index("byte-verify") < index("membership-after-copy"));
}
void failures() {
    for (const std::string stage : {"inventory", "read", "write", "byte-verify", "identity"}) {
        for (bool throws : {false, true}) {
            World w; Resolver r(w); BackendDouble b(w); CopyDouble c(w);
            c.fail = stage; c.throws = throws;
            const auto result = stage_snapshot_roots(roots, r, b, c);
            check(!result.ok && !result.staged_verified && result.staging_directory.empty());
            check(result.staging_discarded && w.staged.empty() && c.discards == 1 && b.cleanups == 1);
            check(!result.error.empty() && !result.capture_enabled && !result.windows_validated);
        }
    }
    for (bool extra : {false, true}) {
        World w; Resolver r(w); BackendDouble b(w); CopyDouble c(w);
        c.extra = extra; c.corrupt = !extra;
        check(!stage_snapshot_roots(roots, r, b, c).ok && w.staged.empty() && b.cleanups == 1);
    }
    for (const std::string stage : {"initialize", "context", "start", "add", "do", "query", "membership", "device", "membership-after-copy", "cleanup"}) {
        World w; Resolver r(w); BackendDouble b(w); CopyDouble c(w); b.fail = stage;
        const auto result = stage_snapshot_roots(roots, r, b, c);
        check(!result.ok && !result.staged_verified && result.staging_directory.empty() && w.staged.empty());
        check(b.starts <= 1 && b.dos <= 1 && b.cleanups <= 1); // No retry or per-volume fallback.
        if (stage == "device" || stage == "membership-after-copy" || stage == "cleanup") check(c.discards == 1);
        else check(c.stages == 0);
    }
    World w; Resolver r(w); BackendDouble b(w); CopyDouble c(w);
    const auto result = stage_snapshot_roots({"C:\\store", "missing"}, r, b, c);
    check(!result.ok && b.starts == 0 && c.stages == 0);
}
void failed_discard() {
    World w; Resolver r(w); BackendDouble b(w); CopyDouble c(w);
    c.fail = "byte-verify"; c.discard_fails = true;
    const auto result = stage_snapshot_roots(roots, r, b, c);
    check(!result.ok && !result.staging_discarded && result.shadows_released);
    check(result.error == "staged byte verification failed" && result.staging_directory.empty());
    check(result.staging_cleanup_error == "private staging cleanup incomplete");
    for (const std::string stage : {"inventory", "read", "write", "byte-verify"}) {
        World world; Resolver resolver(world); BackendDouble backend(world); CopyDouble copier(world);
        copier.fail = stage; copier.discard_fails = true; backend.fail = "cleanup";
        const auto failed = stage_snapshot_roots(roots, resolver, backend, copier);
        check(!failed.ok && !failed.staged_verified && !failed.shadows_released && !failed.staging_discarded);
        check(!failed.error.empty() && !failed.staging_cleanup_error.empty() && failed.staging_directory.empty());
        check(backend.cleanups == 1 && copier.discards == 1 && backend.dos == 1 && backend.starts == 1);
    }
}
}
int main() {
    success(); failures(); failed_discard();
    std::puts("synthetic held-set byte-copy lifecycle checks passed; no Windows runtime executed");
}
