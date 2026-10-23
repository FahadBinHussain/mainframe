#include "vss_client.h"
#include "vsbackup.h"
#include <cstdio>
#include <stdexcept>
using namespace wacli::vss;
namespace {
void ok(bool v, const char *m) { if (!v) throw std::runtime_error(m); }
std::string vol(unsigned n) { char b[80]; std::snprintf(b,sizeof b,"\\\\?\\volume{%08x-0000-0000-0000-000000000000}\\",n); return b; }
std::wstring wvol(unsigned n) { const auto x=vol(n); return std::wstring(x.begin(), x.end()); }
void setup(std::unique_ptr<Backend>& b, std::string& set, std::string& sid) {
  fake_vss::reset(); b=make_native_backend(); std::string e;
  ok(b->initialize(e),"initialize"); ok(b->set_writerless_backup_context(e),"context");
  ok(b->start_snapshot_set(set,e),"start"); ok(b->add_to_snapshot_set(vol(1),sid,e),"add");
}
void finished_device_regression() {
  std::unique_ptr<Backend> b; std::string set,sid; setup(b,set,sid); std::string e,device;
  ok(!b->snapshot_device({sid,vol(1)},device,e),"device before finished");
  ok(b->do_snapshot_set(e),"do"); ok(b->query_status(e)==AsyncState::finished,"finished");
  ok(b->verify_snapshot_set({{sid,vol(1)}},e),"verify");
  ok(b->snapshot_device({sid,vol(1)},device,e),"device after finished");
  ok(!device.empty(),"device nonempty");
  ok(!b->snapshot_device({"bad",vol(1)},device,e),"wrong id");
  ok(b->cleanup(true,1).complete,"cleanup"); ok(fake_vss::deleted,"deleted");
  ok(!b->snapshot_device({sid,vol(1)},device,e),"device after cleanup");
}
void property_rejection() {
  std::unique_ptr<Backend> b; std::string set,sid; setup(b,set,sid); std::string e;
  ok(b->do_snapshot_set(e),"do"); ok(b->query_status(e)==AsyncState::finished,"finished");
  auto &p=fake_vss::members.begin()->second; p.first=wvol(9);
  ok(!b->verify_snapshot_set({{sid,vol(1)}},e),"wrong volume");
  b->cleanup(true,1);
  setup(b,set,sid); ok(b->do_snapshot_set(e),"do2"); ok(b->query_status(e)==AsyncState::finished,"finished2");
  fake_vss::members.begin()->second.second.clear();
  std::string device; ok(!b->snapshot_device({sid,vol(1)},device,e),"empty device"); b->cleanup(true,1);
}
void terminal_failures_and_cancel() {
  for (HRESULT state : {VSS_S_ASYNC_CANCELLED, (HRESULT)0x80042306L}) {
    std::unique_ptr<Backend> b; std::string set,sid; setup(b,set,sid); std::string e;
    fake_vss::terminal=state; ok(b->do_snapshot_set(e),"do failure");
    auto observed=b->query_status(e); ok(observed==AsyncState::cancelled || observed==AsyncState::failed,"bad terminal");
    std::string device; ok(!b->snapshot_device({sid,vol(1)},device,e),"device failed state");
    ok(b->cleanup(false,1).complete,"cleanup failed state");
  }
  std::unique_ptr<Backend> b; std::string set,sid; setup(b,set,sid); std::string e;
  fake_vss::terminal=VSS_S_ASYNC_PENDING; ok(b->do_snapshot_set(e),"do pending");
  auto result=b->cleanup(false,1); ok(result.complete,"cancel cleanup");
  ok(fake_vss::cancel_called,"cancel observed"); ok(!fake_vss::delete_before_cancel,"delete after cancel");
}
void resolver_stub() { auto r=make_native_resolver(); ResolvedRoot out; std::string e; ok(!r->resolve("C:\\x",out,e),"resolver stub rejects fake OS"); }
}
int main() {
  finished_device_regression(); property_rejection(); terminal_failures_and_cancel(); resolver_stub();
  std::puts("native VSS backend synthetic tests passed; no Windows runtime executed");
}
