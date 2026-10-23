#include "vss_client.h"
#include <cstdio>
#include <map>
#include <stdexcept>
#include <utility>
using namespace wacli::vss;
namespace {
void require(bool value) { if (!value) throw std::runtime_error("synthetic assertion failed"); }
std::string volume(unsigned value) {
    char text[80]{};
    std::snprintf(text, sizeof(text), "\\\\?\\volume{%08x-0000-0000-0000-000000000000}\\", value);
    return text;
}
struct Resolver final : VolumeResolver {
    std::map<std::string, std::string> members;
    unsigned calls = 0;
    bool mismatch = false;
    bool resolve(const std::string& root, ResolvedRoot& out, std::string& error) override {
        ++calls;
        const auto found = members.find(root);
        if (found == members.end()) { error = "unsupported synthetic root"; return false; }
        out = {mismatch ? "other" : root, found->second};
        return true;
    }
};
struct Fake final : Backend {
    std::vector<std::string> calls;
    std::vector<std::string> volumes;
    std::string reject;
    std::string throws;
    bool empty_set = false;
    bool empty_snapshot = false;
    bool cleanup_fails = false;
    AsyncState status = AsyncState::finished;
    unsigned pending = 0;
    unsigned queries = 0;
    unsigned cleanups = 0;
    bool cleanup_finished = false;
    std::size_t cleanup_expected = 0;
    bool stage(const std::string& name, std::string& error) {
        calls.push_back(name);
        if (throws == name) throw std::runtime_error("injected");
        if (reject == name) { error = "injected stage failure"; return false; }
        return true;
    }
    bool initialize(std::string& error) override { return stage("initialize", error); }
    bool set_writerless_backup_context(std::string& error) override { return stage("context", error); }
    bool start_snapshot_set(std::string& id, std::string& error) override {
        if (!stage("start", error)) return false;
        id = empty_set ? "" : "set";
        return true;
    }
    bool add_to_snapshot_set(const std::string& vol, std::string& id, std::string& error) override {
        if (!stage("add", error)) return false;
        volumes.push_back(vol);
        id = empty_snapshot ? "" : "snapshot:" + vol;
        return true;
    }
    bool do_snapshot_set(std::string& error) override { return stage("do", error); }
    AsyncState query_status(std::string& error) override {
        ++queries;
        if (!stage("query", error)) return AsyncState::failed;
        if (queries <= pending) return AsyncState::pending;
        return status;
    }
    bool verify_snapshot_set(const std::vector<SnapshotInfo>& expected, std::string& error) override {
        require(expected.size() == volumes.size());
        return stage("verify", error);
    }
    CleanupResult cleanup(bool finished, std::size_t expected) noexcept override {
        ++cleanups;
        cleanup_finished = finished;
        cleanup_expected = expected;
        // No allocating or throwing assertions in this noexcept fake path.
        return {!cleanup_fails, cleanup_fails ? 0 : expected,
                cleanup_fails ? "injected partial deletion" : ""};
    }
};
Resolver fixture() { Resolver r; r.members = {{"C:\\approved", volume(1)},
    {"C:\\also-approved", volume(1)}, {"D:\\approved", volume(2)}}; return r; }
void successful_membership() {
    auto r = fixture(); Fake b;
    const auto x = probe_volumes({"C:\\approved", "C:\\also-approved", "D:\\approved"}, r, b);
    require(x.ok && x.shadows_released && x.cleanup.complete);
    require(!x.capture_enabled && !x.windows_validated);
    require(x.mappings.size() == 3 && x.snapshots.size() == 2 && b.cleanups == 1);
    require(b.cleanup_finished && b.cleanup_expected == 2 && x.cleanup.deleted == 2);
    require((b.calls == std::vector<std::string>{"initialize", "context", "start", "add", "add", "do", "query", "verify"}));
    require(canonical_volume(volume(1)));
    require(!canonical_volume("{00000000-0000-0000-0000-000000000000}"));
    auto uppercase = volume(10); uppercase[11] = 'A'; require(!canonical_volume(uppercase));
    require(!canonical_volume(volume(1) + "extra"));
}
void preflight_refusal() {
    for (const auto& roots : std::vector<std::vector<std::string>>{{}, {"missing"}, {"C:\\approved", "missing"}}) {
        auto r = fixture(); Fake b; const auto x = probe_volumes(roots, r, b);
        require(!x.ok && b.calls.empty() && b.cleanups == 0);
    }
    auto r = fixture(); r.mismatch = true; Fake b;
    require(!probe_volumes({"C:\\approved"}, r, b).ok && b.calls.empty());
    r.mismatch = false; r.members["C:\\approved"] = "invalid";
    require(!probe_volumes({"C:\\approved"}, r, b).ok && b.calls.empty());
    r.members.clear(); std::vector<std::string> roots;
    for (unsigned i = 0; i < 65; ++i) { roots.push_back("root" + std::to_string(i)); r.members[roots.back()] = volume(i); }
    require(!probe_volumes(roots, r, b).ok && b.calls.empty());
    roots.pop_back();
    const auto allowed = probe_volumes(roots, r, b);
    require(allowed.ok && allowed.snapshots.size() == 64);
}
void stage_failures() {
    for (const std::string stage : {"initialize", "context", "start", "add", "do", "query", "verify"}) {
        auto r = fixture(); Fake b; b.reject = stage;
        const auto x = probe_volumes({"C:\\approved"}, r, b);
        require(!x.ok && !x.error.empty());
        require(b.cleanups == ((stage == "initialize" || stage == "context" || stage == "start") ? 0u : 1u));
        if (b.cleanups) require(x.cleanup.complete);
    }
    for (const std::string stage : {"add", "do", "query", "verify"}) {
        auto r = fixture(); Fake b; b.throws = stage;
        const auto x = probe_volumes({"C:\\approved"}, r, b);
        require(!x.ok && b.cleanups == 1 && x.cleanup.complete);
    }
    for (bool set : {true, false}) {
        auto r = fixture(); Fake b; b.empty_set = set; b.empty_snapshot = !set;
        const auto x = probe_volumes({"C:\\approved"}, r, b);
        require(!x.ok && b.cleanups == 1);
    }
}
void async_and_cleanup() {
    for (auto state : {AsyncState::cancelled, AsyncState::failed}) {
        auto r = fixture(); Fake b; b.status = state;
        const auto x = probe_volumes({"C:\\approved"}, r, b);
        require(!x.ok && b.cleanups == 1 && !b.cleanup_finished);
    }
    auto r = fixture(); Fake timeout; timeout.pending = 1000;
    const auto t = probe_volumes({"C:\\approved"}, r, timeout);
    require(!t.ok && timeout.queries == 600 && timeout.cleanups == 1);
    Fake eventually; eventually.pending = 2;
    require(probe_volumes({"C:\\approved"}, r, eventually).ok && eventually.queries == 3);
    for (const std::string stage : {"", "add", "query", "verify"}) {
        Fake b; b.reject = stage; b.cleanup_fails = true;
        const auto x = probe_volumes({"C:\\approved"}, r, b);
        require(!x.ok && !x.cleanup.complete && !x.shadows_released && !x.cleanup.error.empty());
        if (!stage.empty()) require(x.error == "injected stage failure");
    }
}
}
int main() {
    successful_membership(); preflight_refusal(); stage_failures(); async_and_cleanup();
    std::puts("synthetic VSS transaction checks passed; no Windows runtime executed");
}
