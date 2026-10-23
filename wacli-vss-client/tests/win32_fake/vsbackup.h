#pragma once
#include <windows.h>
#include <map>
#include <string>
#include <vector>
#include <cwchar>
#include <cstdlib>
#include <cstring>

#ifndef COINIT_MULTITHREADED
#define COINIT_MULTITHREADED 0
#define RPC_C_AUTHN_LEVEL_PKT_PRIVACY 6
#define RPC_C_IMP_LEVEL_IMPERSONATE 3
#define EOAC_NONE 0
#endif
#ifndef S_OK
#define S_OK ((HRESULT)0)
#define S_FALSE ((HRESULT)1)
#define E_FAIL ((HRESULT)0x80004005L)
#define E_UNEXPECTED ((HRESULT)0x8000FFFFL)
#endif
#ifndef SUCCEEDED
#define SUCCEEDED(x) ((x) >= 0)
#endif
#ifndef GUID_NULL
#define GUID_NULL GUID{0,0,0,{0,0,0,0,0,0,0,0}}
#endif

using INT = int;
using ULONG = unsigned long;
using VSS_PWSZ = wchar_t*;
enum VSS_OBJECT_TYPE { VSS_OBJECT_SNAPSHOT_SET = 3 };
enum VSS_SNAPSHOT_STATE { VSS_SS_UNKNOWN = 0, VSS_SS_CREATED = 3 };
static constexpr HRESULT VSS_S_ASYNC_PENDING = 0x00042309L;
static constexpr HRESULT VSS_S_ASYNC_FINISHED = 0x0004230AL;
static constexpr HRESULT VSS_S_ASYNC_CANCELLED = 0x0004230BL;
static constexpr HRESULT VSS_E_OBJECT_NOT_FOUND = (HRESULT)0x80042308L;
static constexpr long VSS_CTX_FILE_SHARE_BACKUP = 0x00000010L;

struct VSS_SNAPSHOT_PROP {
  GUID m_SnapshotId{};
  GUID m_SnapshotSetId{};
  LONG m_lSnapshotsCount{};
  VSS_SNAPSHOT_STATE m_eStatus = VSS_SS_UNKNOWN;
  wchar_t *m_pwszOriginalVolumeName = nullptr;
  wchar_t *m_pwszSnapshotDeviceObject = nullptr;
};

namespace fake_vss {
inline GUID set_id{0x100,0,0,{0,0,0,0,0,0,0,1}};
inline bool initialized = false, context_set = false, deleted = false;
inline bool cancel_called = false, delete_before_cancel = false;
inline HRESULT init_hr = S_OK, context_hr = S_OK, start_hr = S_OK;
inline HRESULT support_hr = S_OK, add_hr = S_OK, do_hr = S_OK, query_hr = S_OK;
inline HRESULT delete_hr = S_OK;
inline HRESULT terminal = VSS_S_ASYNC_FINISHED;
inline std::map<unsigned long, std::pair<std::wstring,std::wstring>> members;
inline unsigned long next_id = 1;
inline void reset() {
  initialized = context_set = deleted = cancel_called = delete_before_cancel = false;
  init_hr=context_hr=start_hr=support_hr=add_hr=do_hr=query_hr=delete_hr=S_OK;
  terminal=VSS_S_ASYNC_FINISHED; members.clear(); next_id=1;
  set_id = {0x100,0,0,{0,0,0,0,0,0,0,1}};
}
inline bool eq(const GUID&a,const GUID&b) { return a.Data1==b.Data1&&a.Data2==b.Data2&&a.Data3==b.Data3&&std::memcmp(a.Data4,b.Data4,8)==0; }
inline std::wstring guid(GUID g) { wchar_t b[40]; swprintf(b,40,L"{%08lx-0000-0000-0000-000000000000}",g.Data1); return b; }
}

inline BOOL IsEqualGUID(const GUID&a,const GUID&b) { return fake_vss::eq(a,b); }
inline HRESULT CoInitializeEx(void*, DWORD) { return S_OK; }
inline HRESULT CoInitializeSecurity(void*, LONG, void*, void*, DWORD, DWORD, void*, DWORD, void*) { return S_OK; }
inline void CoUninitialize() {}
inline void Sleep(DWORD) {}
inline BOOL GetVolumePathNameW(LPCWSTR, LPWSTR, DWORD) { return FALSE; }
inline BOOL GetVolumeNameForVolumeMountPointW(LPCWSTR, LPWSTR, DWORD) { return FALSE; }

class IVssAsync {
public: virtual HRESULT QueryStatus(HRESULT*, INT*) = 0; virtual HRESULT Cancel() = 0; virtual ULONG Release() = 0; protected: virtual ~IVssAsync() = default;
};
class IVssBackupComponents {
public:
  virtual HRESULT InitializeForBackup(LPCWSTR) = 0;
  virtual HRESULT SetContext(LONG) = 0;
  virtual HRESULT StartSnapshotSet(GUID*) = 0;
  virtual HRESULT IsVolumeSupported(GUID, VSS_PWSZ, BOOL*) = 0;
  virtual HRESULT AddToSnapshotSet(VSS_PWSZ, GUID, GUID*) = 0;
  virtual HRESULT DoSnapshotSet(IVssAsync**) = 0;
  virtual HRESULT GetSnapshotProperties(GUID, VSS_SNAPSHOT_PROP*) = 0;
  virtual HRESULT DeleteSnapshots(GUID,VSS_OBJECT_TYPE,BOOL,LONG*,GUID*) = 0;
  virtual ULONG Release() = 0; protected: virtual ~IVssBackupComponents() = default;
};

class fake_async final : public IVssAsync {
public:
  HRESULT QueryStatus(HRESULT *s, INT *r) override { if (r) *r=0; if (fake_vss::query_hr<0) return fake_vss::query_hr; *s=fake_vss::terminal; return S_OK; }
  HRESULT Cancel() override { fake_vss::cancel_called=true; fake_vss::terminal=VSS_S_ASYNC_CANCELLED; return S_OK; }
  ULONG Release() override { delete this; return 0; }
};
class fake_components final : public IVssBackupComponents {
public:
  HRESULT InitializeForBackup(LPCWSTR) override { fake_vss::initialized=SUCCEEDED(fake_vss::init_hr); return fake_vss::init_hr; }
  HRESULT SetContext(LONG) override { fake_vss::context_set=SUCCEEDED(fake_vss::context_hr); return fake_vss::context_hr; }
  HRESULT StartSnapshotSet(GUID *g) override { if (SUCCEEDED(fake_vss::start_hr)) *g=fake_vss::set_id; return fake_vss::start_hr; }
  HRESULT IsVolumeSupported(GUID,VSS_PWSZ,BOOL *ok) override { if(ok)*ok=SUCCEEDED(fake_vss::support_hr); return fake_vss::support_hr; }
  HRESULT AddToSnapshotSet(VSS_PWSZ v,GUID,GUID *g) override { if (FAILED(fake_vss::add_hr)) return fake_vss::add_hr; *g={0x200u+fake_vss::next_id++,0,0,{0,0,0,0,0,0,0,2}}; fake_vss::members[g->Data1]={v,L"\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1"}; return S_OK; }
  HRESULT DoSnapshotSet(IVssAsync **a) override { if(FAILED(fake_vss::do_hr)) return fake_vss::do_hr; *a=new fake_async; return S_OK; }
  HRESULT GetSnapshotProperties(GUID g,VSS_SNAPSHOT_PROP *p) override { auto it=fake_vss::members.find(g.Data1); if(it==fake_vss::members.end()) return E_FAIL; p->m_SnapshotId=g; p->m_SnapshotSetId=fake_vss::set_id; p->m_lSnapshotsCount=(LONG)fake_vss::members.size(); p->m_eStatus=VSS_SS_CREATED; p->m_pwszOriginalVolumeName=(wchar_t*)malloc((it->second.first.size()+1)*sizeof(wchar_t)); p->m_pwszSnapshotDeviceObject=(wchar_t*)malloc((it->second.second.size()+1)*sizeof(wchar_t)); wcscpy(p->m_pwszOriginalVolumeName,it->second.first.c_str()); wcscpy(p->m_pwszSnapshotDeviceObject,it->second.second.c_str()); return S_OK; }
  HRESULT DeleteSnapshots(GUID,VSS_OBJECT_TYPE,BOOL,LONG *n,GUID *u) override { if(!fake_vss::cancel_called && fake_vss::terminal==VSS_S_ASYNC_PENDING) fake_vss::delete_before_cancel=true; if(FAILED(fake_vss::delete_hr)) return fake_vss::delete_hr; if(n)*n=(LONG)fake_vss::members.size(); if(u)*u=GUID_NULL; fake_vss::deleted=true; return S_OK; }
  ULONG Release() override { delete this; return 0; }
};
inline HRESULT CreateVssBackupComponents(IVssBackupComponents **p) { *p=new fake_components; return S_OK; }
inline void VssFreeSnapshotProperties(VSS_SNAPSHOT_PROP *p) { free(p->m_pwszOriginalVolumeName); free(p->m_pwszSnapshotDeviceObject); p->m_pwszOriginalVolumeName=p->m_pwszSnapshotDeviceObject=nullptr; }
