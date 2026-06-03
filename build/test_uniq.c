/* stub_win.c P0 픽스 메커니즘 검증: GetTempFileNameW 유니크 디렉터리 + rmrf 정리.
 * (stub_win.c 의 해당 코드와 동일 API/로직. UAC 없이 동시실행/누수만 검증) */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static void rmrf(const wchar_t *dir) {
    size_t len = wcslen(dir);
    wchar_t *from = (wchar_t *)calloc(len + 2, sizeof(wchar_t));
    if (!from) return;
    wcscpy(from, dir);
    from[len + 1] = L'\0';
    SHFILEOPSTRUCTW op = {0};
    op.wFunc = FO_DELETE; op.pFrom = from; op.fFlags = FOF_NO_UI;
    SHFileOperationW(&op);
    free(from);
}

int wmain(void) {
    wchar_t tmp[MAX_PATH]; GetTempPathW(MAX_PATH, tmp);
    wchar_t uniq[MAX_PATH];
    if (GetTempFileNameW(tmp, L"nco", 0, uniq) == 0) { wprintf(L"FAIL gettemp\n"); return 1; }
    DeleteFileW(uniq);
    if (!CreateDirectoryW(uniq, NULL)) { wprintf(L"FAIL mkdir\n"); return 1; }
    /* 추출 시뮬: 폴더 안에 payload.tgz + 하위파일 생성 */
    wchar_t pf[MAX_PATH]; _snwprintf(pf, MAX_PATH, L"%ls\\payload.tgz", uniq); pf[MAX_PATH-1]=0;
    FILE *o = _wfopen(pf, L"wb"); if (o){ fwrite("DATA",1,4,o); fclose(o); }
    int before = (GetFileAttributesW(uniq) != INVALID_FILE_ATTRIBUTES);
    wprintf(L"UNIQ=%ls BEFORE=%d\n", uniq, before);
    fflush(stdout);
    Sleep(1000); /* 동시실행 겹치게 — 충돌 시 같은 경로면 드러남 */
    rmrf(uniq);
    int after = (GetFileAttributesW(uniq) != INVALID_FILE_ATTRIBUTES);
    wprintf(L"CLEANED AFTER=%d\n", after);
    return after == 0 ? 0 : 2;
}
