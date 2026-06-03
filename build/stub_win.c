/* nco-back — Windows 자가추출 설치 스텁 (PE .exe)
 * 구조:  [이 스텁 .exe][payload tar.gz][8바이트 LE 아카이브크기]
 * 동작:  자기 파일 끝의 8바이트로 아카이브 크기를 읽어 그만큼을 유니크 임시폴더의 payload.tgz 로 추출,
 *        Windows 내장 tar.exe 로 같은 유니크 폴더에 풀고, install.ps1 을 관리자(UAC)로 실행.
 *        설치 종료 후 임시 추출본 정리(누수 방지). NCO_KEEP_EXTRACT=1 이면 유지(디버깅).
 * 빌드:  x86_64-w64-mingw32-gcc -O2 -municode -o stub_win.exe stub_win.c -lshell32
 * 조립:  cat stub_win.exe payload.tgz footer8 > NCO-Installer.exe   (footer8 = LE uint64 아카이브크기)
 * 요구:  Windows 10 1803+ (System32\tar.exe 내장)
 *
 * P0 수정(2026-06): ①TMPDIR 누수 — 고정 %TEMP%\nco-back 경로 추출후 미삭제 → 유니크폴더+설치후 정리.
 *                   ②PATH 충돌 — 고정 파일명(nco-back-payload.tgz)이라 동시실행 충돌 → GetTempFileNameW 유니크 서브디렉터리.
 *                   (stub_linux.sh 의 mktemp -d + NCO_KEEP_EXTRACT 게이트와 동일 의미)
 */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <wchar.h>

static void fail(const wchar_t *m) {
    fwprintf(stderr, L"[X] %ls (err=%lu)\n", m, GetLastError());
}

/* 디렉터리 재귀 삭제 (SHFileOperationW, UI 없음). pFrom 은 이중 NUL 종료 필요. */
static void rmrf(const wchar_t *dir) {
    size_t len = wcslen(dir);
    wchar_t *from = (wchar_t *)calloc(len + 2, sizeof(wchar_t));
    if (!from) return;
    wcscpy(from, dir);
    from[len + 1] = L'\0';            /* 이중 NUL 종료 */
    SHFILEOPSTRUCTW op = {0};
    op.wFunc  = FO_DELETE;
    op.pFrom  = from;
    op.fFlags = FOF_NO_UI;            /* 조용히: 확인/에러UI 없음 */
    SHFileOperationW(&op);
    free(from);
}

int wmain(int argc, wchar_t **argv) {
    int rc = 1;
    int dirCreated = 0;
    wchar_t outdir[MAX_PATH] = L"";   /* 유니크 추출 폴더 */
    wchar_t tgz[MAX_PATH];

    /* NCO_KEEP_EXTRACT=1 이면 추출본 유지(정리 안 함) */
    wchar_t keepEnv[8];
    DWORD kn = GetEnvironmentVariableW(L"NCO_KEEP_EXTRACT", keepEnv, 8);
    int keep = (kn > 0 && kn < 8 && keepEnv[0] == L'1');

    wchar_t self[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) { fail(L"실행경로 확인 실패"); return 1; }

    FILE *f = _wfopen(self, L"rb");
    if (!f) { fail(L"자기 파일 열기 실패"); return 1; }

    /* 파일 크기 */
    if (_fseeki64(f, 0, SEEK_END) != 0) { fail(L"seek end"); fclose(f); return 1; }
    long long fileSize = _ftelli64(f);
    if (fileSize < 8) { fail(L"파일 손상(too small)"); fclose(f); return 1; }

    /* 끝 8바이트 = 아카이브 크기 (little-endian) */
    if (_fseeki64(f, fileSize - 8, SEEK_SET) != 0) { fail(L"seek footer"); fclose(f); return 1; }
    unsigned char fb[8];
    if (fread(fb, 1, 8, f) != 8) { fail(L"footer 읽기"); fclose(f); return 1; }
    unsigned long long archSize = 0;
    for (int i = 7; i >= 0; --i) archSize = (archSize << 8) | fb[i];

    long long archStart = fileSize - 8 - (long long)archSize;
    if (archStart < 0) { fail(L"아카이브 오프셋 오류"); fclose(f); return 1; }

    /* %TEMP% 경로 */
    wchar_t tmp[MAX_PATH];
    DWORD tn = GetTempPathW(MAX_PATH, tmp);
    if (tn == 0 || tn >= MAX_PATH) { fail(L"TEMP 경로"); fclose(f); return 1; }

    /* ① + ② 수정: 동시실행 충돌·누수 방지를 위해 유니크 임시 서브디렉터리 생성.
     * GetTempFileNameW 가 원자적으로 유니크 파일을 만들면 → 삭제 후 같은 이름으로 디렉터리 생성. */
    wchar_t uniq[MAX_PATH];
    if (GetTempFileNameW(tmp, L"nco", 0, uniq) == 0) { fail(L"유니크 임시경로 생성 실패"); fclose(f); return 1; }
    DeleteFileW(uniq);                                  /* 플레이스홀더 파일 제거 */
    if (!CreateDirectoryW(uniq, NULL)) { fail(L"임시 추출폴더 생성 실패"); fclose(f); return 1; }
    dirCreated = 1;
    wcsncpy(outdir, uniq, MAX_PATH - 1); outdir[MAX_PATH - 1] = 0;
    _snwprintf(tgz, MAX_PATH, L"%ls\\payload.tgz", outdir); tgz[MAX_PATH - 1] = 0;

    /* 아카이브 바이트를 tgz 로 기록 */
    if (_fseeki64(f, archStart, SEEK_SET) != 0) { fail(L"seek archive"); fclose(f); goto done; }
    FILE *out = _wfopen(tgz, L"wb");
    if (!out) { fail(L"tgz 생성 실패"); fclose(f); goto done; }
    unsigned char buf[65536];
    unsigned long long left = archSize;
    while (left > 0) {
        size_t want = left < sizeof(buf) ? (size_t)left : sizeof(buf);
        size_t got = fread(buf, 1, want, f);
        if (got == 0) { fail(L"아카이브 읽기 중단"); fclose(out); fclose(f); goto done; }
        fwrite(buf, 1, got, out);
        left -= got;
    }
    fclose(out); fclose(f);
    wprintf(L"[>] payload 추출 중...\n");

    /* tar 로 추출 (Windows 10 1803+ 내장 bsdtar) */
    wchar_t tarcmd[2048];
    _snwprintf(tarcmd, 2048, L"tar.exe -xzf \"%ls\" -C \"%ls\"", tgz, outdir);
    tarcmd[2047] = 0;
    STARTUPINFOW si = {0}; si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {0};
    if (!CreateProcessW(NULL, tarcmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        fail(L"tar 실행 실패 (Windows 10 1803+ 필요)"); goto done;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD ec = 1; GetExitCodeProcess(pi.hProcess, &ec);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    if (ec != 0) { fail(L"tar 추출 실패"); goto done; }
    wprintf(L"[OK] 추출 완료 → %ls\n[>] 관리자 권한으로 설치 시작...\n", outdir);

    /* install.ps1 을 UAC 승격해서 실행 */
    wchar_t extra[1024] = L"";
    for (int i = 1; i < argc && i < 16; ++i) {
        wcsncat(extra, L" ", 1023 - wcslen(extra));
        wcsncat(extra, argv[i], 1023 - wcslen(extra));
    }
    wchar_t params[2048];
    _snwprintf(params, 2048,
        L"-NoProfile -ExecutionPolicy Bypass -File \"%ls\\install.ps1\"%ls", outdir, extra);
    params[2047] = 0;

    SHELLEXECUTEINFOW sei = {0};
    sei.cbSize = sizeof(sei);
    sei.fMask  = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = L"powershell.exe";
    sei.lpParameters = params;
    sei.lpDirectory  = outdir;
    sei.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&sei)) {
        if (GetLastError() == ERROR_CANCELLED)
            fwprintf(stderr, L"[!] 관리자 승격이 취소되었습니다.\n");
        else fail(L"install.ps1 실행 실패");
        goto done;
    }
    if (sei.hProcess) { WaitForSingleObject(sei.hProcess, INFINITE); CloseHandle(sei.hProcess); }
    rc = 0;

done:
    /* P0 누수수정: 설치 종료 후 유니크 추출폴더 정리(payload.tgz 포함). NCO_KEEP_EXTRACT=1 이면 유지. */
    if (dirCreated) {
        if (keep) {
            wprintf(L"  (추출 유지: %ls)\n", outdir);
        } else {
            rmrf(outdir);
            wprintf(L"  (임시 추출본 정리됨. 유지하려면 NCO_KEEP_EXTRACT=1)\n");
        }
    }
    return rc;
}
