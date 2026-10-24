#include "vss_client.h"
#include "windows.h"
#include <cstdio>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
using namespace wacli::vss;
using namespace fake_win32;
static std::wstring wide(const std::string &s) {
  return std::wstring(s.begin(), s.end());
}
static void ok(bool v, const char *m) {
  if (!v)
    throw std::runtime_error(m);
}
struct B final : Backend {
  std::wstring shadow = L"SHADOW";
  bool device_ok = true;
  bool initialize(std::string &) override { return true; }
  bool set_writerless_backup_context(std::string &) override { return true; }
  bool start_snapshot_set(std::string &, std::string &) override {
    return true;
  }
  bool add_to_snapshot_set(const std::string &, std::string &,
                           std::string &) override {
    return true;
  }
  bool do_snapshot_set(std::string &) override { return true; }
  AsyncState query_status(std::string &) override {
    return AsyncState::finished;
  }
  bool verify_snapshot_set(const std::vector<SnapshotInfo> &,
                           std::string &) override {
    return true;
  }
  bool snapshot_device(const SnapshotInfo &, std::string &d,
                       std::string &e) override {
    if (!device_ok) {
      e = "device";
      return false;
    }
    d = "\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1";
    return true;
  }
  CleanupResult cleanup(bool, std::size_t) noexcept override { return {}; }
};
static void setup() {
  reset();
  dir(L"C:");
  dir(L"C:\\PARENT");
  dir(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1");
  dir(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src");
  dir(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store");
  dir(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\profile");
  dir(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\media");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\binary",
       std::string("\0\xff\r\n", 4));
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\empty", "");
  dir(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\empty-dir");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\session.db",
       std::string("\0\xff\r\n", 4));
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\session.db-wal",
       "session-wal");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\session.db-shm",
       "session-shm");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\session.db-journal",
       "session-journal");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\wacli.db",
       "wacli-db");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\wacli.db-wal",
       "wacli-wal");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\wacli.db-shm",
       "wacli-shm");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\store\\wacli.db-journal",
       "wacli-journal");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\profile\\config.json",
       "synthetic-profile-config");
  file(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\media\\blob",
       std::string("\0\x80\xff", 3));
}
static std::unique_ptr<SnapshotCopy> make() {
  return make_native_snapshot_copy("C:\\PARENT");
}
static bool stage(std::unique_ptr<SnapshotCopy> &c, std::string &e) {
  B b;
  return c->stage({{"C:\\src", "v1"}}, {{"s1", "v1"}}, b, e);
}
static void fake_cleanup_contract() {
  reset();
  dir(L"C:");
  dir(L"C:\\PARENT");
  auto h = CreateFileW(L"C:\\PARENT", FILE_READ_ATTRIBUTES,
                       FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                       OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  ok(h != INVALID_HANDLE_VALUE, "fake directory handle opened");
  ok(!RemoveDirectoryW(L"C:\\PARENT"),
     "live no-delete handle blocks directory removal");
  CloseHandle(h);
  file(L"C:\\PARENT\\child", "x");
  ok(!RemoveDirectoryW(L"C:\\PARENT"), "nonempty directory removal rejected");
  ok(DeleteFileW(L"C:\\PARENT\\child"), "fake child deleted");
  ok(RemoveDirectoryW(L"C:\\PARENT"), "empty directory removed");
}
static void success_and_shadow_only() {
  setup();
  std::string e;
  auto c = make();
  ok(stage(c, e), e.c_str());
  ok(!c->staging_directory().empty(), "stage identity");
  auto s = wide(c->staging_directory());
  auto it = fs.find(s + L"\\root0\\binary");
  ok(it != fs.end() && it->second.bytes == std::string("\0\xff\r\n", 4),
     "binary copy");
  ok(fs.count(s + L"\\root0\\empty"), "empty file");
  ok(fs.count(s + L"\\root0\\empty-dir"), "empty directory");
  const std::vector<std::pair<std::wstring, std::string>> wacli_inputs = {
      {L"store\\session.db", std::string("\0\xff\r\n", 4)},
      {L"store\\session.db-wal", "session-wal"},
      {L"store\\session.db-shm", "session-shm"},
      {L"store\\session.db-journal", "session-journal"},
      {L"store\\wacli.db", "wacli-db"},
      {L"store\\wacli.db-wal", "wacli-wal"},
      {L"store\\wacli.db-shm", "wacli-shm"},
      {L"store\\wacli.db-journal", "wacli-journal"},
      {L"profile\\config.json", "synthetic-profile-config"},
      {L"media\\blob", std::string("\0\x80\xff", 3)},
  };
  for (const auto &input : wacli_inputs) {
    const auto staged = fs.find(s + L"\\root0\\" + input.first);
    ok(staged != fs.end() && staged->second.bytes == input.second,
       "WACLI input and SQLite sidecar copied byte-for-byte");
  }
  ok(c->discard(e), "discard");
  ok(!fs.count(s), "private stage removed");
}
static void reject_cases() {
  setup();
  fs[L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\bad"]
      .streams = {L":evil:$DATA"};
  std::string e;
  auto c = make();
  ok(!stage(c, e) && e == "alternate stream unsupported", "ADS rejected");
  setup();
  reparse(
      L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\junction",
      true);
  c = make();
  ok(!stage(c, e) && e == "entry unsupported", "junction rejected");
  reset();
  dir(L"C:");
  dir(L"C:\\PARENT");
  dir(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1");
  c = make();
  ok(!stage(c, e), "missing root");
}
static void io_failures() {
  for (int which = 0; which < 4; which++) {
    setup();
    fail_read = which == 0;
    fail_write = which == 1;
    fail_flush = which == 2;
    short_write = which == 3;
    std::string e;
    auto c = make();
    ok(!stage(c, e), "I/O failure rejected");
    ok(c->staging_directory().empty(), "failed stage cleaned");
  }
}
static void directory_ads_and_acl() {
  setup();
  fs[L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\empty-dir"]
      .streams = {L":evil:$DATA"};
  std::string e;
  auto c = make();
  ok(!stage(c, e) && e == "alternate stream unsupported",
     "directory ADS rejected");

  setup();
  auto d = make();
  ok(stage(d, e), e.c_str());
  auto s = wide(d->staging_directory());
  const auto &node = fs.at(s);
  ok(node.had_security_attributes, "staging security attributes recorded");
  ok(node.security_descriptor ==
         L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;S-1-5-21-fake)",
     "staging protected ACL recorded");
  ok(d->discard(e), "ACL staging discard");
}
static void parent_and_source_reparse() {
  setup();
  reparse(L"C:\\PARENT", true);
  std::string e;
  auto c = make();
  ok(!stage(c, e), "reparse parent rejected");
  ok(c->staging_directory().empty(), "reparse parent creates no stage");

  setup();
  reparse(L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1", true);
  c = make();
  ok(!stage(c, e), "source suffix ancestor reparse rejected");
  ok(source_read_count == 0, "reparse rejected before source content read");
}
static void source_overlap_and_staging_inventory() {
  setup();
  std::string e;
  auto c = make();
  B b;
  ok(!c->stage({{"C:\\", "v1"}}, {{"s1", "v1"}}, b, e),
     "whole-drive source overlap rejected");
  ok(c->staging_directory().empty() && source_read_count == 0,
     "whole-drive overlap creates no entries or reads");

  setup();
  auto d = make();
  ok(stage(d, e), e.c_str());
  auto s = wide(d->staging_directory());
  file(s + L"\\extra", "unexpected");
  ok(!d->verify(e) && e == "staging top-level inventory mismatch",
     "extra staged file detected");
  ok(d->discard(e), "extra-file discard");

  setup();
  d = make();
  ok(stage(d, e), e.c_str());
  s = wide(d->staging_directory());
  dir(s + L"\\empty-extra");
  ok(!d->verify(e) && e == "staging top-level inventory mismatch",
     "extra empty directory detected");
  ok(d->discard(e), "extra-directory discard");
}
static void incomplete_enumeration_and_read_tracking() {
  setup();
  fail_enum_after = 1;
  std::string e;
  auto c = make();
  ok(!stage(c, e) && e == "directory enumeration incomplete",
     "incomplete enumeration rejected deterministically");

  setup();
  reparse(
      L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\src\\ancestor",
      true);
  c = make();
  ok(!stage(c, e), "source ancestor reparse rejected");
  ok(source_read_count == 0, "source ancestor reparse has no live reads");

  setup();
  fail_volume_info = true;
  c = make();
  ok(!stage(c, e) && c->staging_directory().empty(), "non-ACL volume rejected");
}
static void verify_corruption_and_cleanup() {
  setup();
  std::string e;
  auto c = make();
  ok(stage(c, e), "stage before corruption");
  auto s = wide(c->staging_directory());
  fs[s + L"\\root0\\binary"].bytes[0] = 'X';
  ok(!c->verify(e), "corruption detected");
  ok(c->discard(e), "discard after corruption");
  setup();
  auto d = make();
  fail_remove = true;
  ok(stage(d, e), "stage cleanup failure setup");
  ok(!d->discard(e) && e == "staging cleanup failed",
     "cleanup failure surfaced");
}
int main() {
  try {
    success_and_shadow_only();
    fake_cleanup_contract();
    reject_cases();
    directory_ads_and_acl();
    parent_and_source_reparse();
    source_overlap_and_staging_inventory();
    incomplete_enumeration_and_read_tracking();
    io_failures();
    verify_corruption_and_cleanup();
    std::puts("native snapshot copier fake-Win32 integration tests passed");
    return 0;
  } catch (const std::exception &e) {
    std::fprintf(stderr, "FAIL: %s\n", e.what());
    return 1;
  }
}
