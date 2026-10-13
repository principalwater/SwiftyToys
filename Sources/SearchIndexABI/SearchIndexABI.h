// SPDX-License-Identifier: MIT
#pragma once
#define CINTERFACE
#define COBJMACROS
#include <windows.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <stddef.h>

// Read-only subset of the documented SearchAPI.h COM ABI. Unused SDK slots are
// declarations only; exposing them as pointers prevents accidental index writes.
typedef struct STSearchManager STSearchManager;
typedef struct STSearchCatalogManager STSearchCatalogManager;
typedef struct STSearchQueryHelper STSearchQueryHelper;
typedef struct STSearchManagerVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(STSearchManager *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(STSearchManager *);
    ULONG (STDMETHODCALLTYPE *Release)(STSearchManager *);
    void *unusedBeforeCatalog[7];
    HRESULT (STDMETHODCALLTYPE *GetCatalog)(STSearchManager *, LPCWSTR, STSearchCatalogManager **);
} STSearchManagerVtbl;
struct STSearchManager { const STSearchManagerVtbl *lpVtbl; };
typedef struct STSearchCatalogManagerVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(STSearchCatalogManager *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(STSearchCatalogManager *);
    ULONG (STDMETHODCALLTYPE *Release)(STSearchCatalogManager *);
    void *unusedBeforeQueryHelper[22];
    HRESULT (STDMETHODCALLTYPE *GetQueryHelper)(STSearchCatalogManager *, STSearchQueryHelper **);
} STSearchCatalogManagerVtbl;
struct STSearchCatalogManager { const STSearchCatalogManagerVtbl *lpVtbl; };
typedef struct STSearchQueryHelperVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(STSearchQueryHelper *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(STSearchQueryHelper *);
    ULONG (STDMETHODCALLTYPE *Release)(STSearchQueryHelper *);
    HRESULT (STDMETHODCALLTYPE *get_ConnectionString)(STSearchQueryHelper *, LPWSTR *);
    HRESULT (STDMETHODCALLTYPE *put_QueryContentLocale)(STSearchQueryHelper *, LCID);
    void *unusedContentGetKeywordAndExpansion[5];
    HRESULT (STDMETHODCALLTYPE *put_QuerySyntax)(STSearchQueryHelper *, int);
    void *unusedSyntaxGetAndContentProperties[3];
    HRESULT (STDMETHODCALLTYPE *put_QuerySelectColumns)(STSearchQueryHelper *, LPCWSTR);
    void *unusedSelectGet;
    HRESULT (STDMETHODCALLTYPE *put_QueryWhereRestrictions)(STSearchQueryHelper *, LPCWSTR);
    void *unusedWhereGetAndSorting[3];
    HRESULT (STDMETHODCALLTYPE *GenerateSQLFromUserQuery)(STSearchQueryHelper *, LPCWSTR, LPWSTR *);
    void *unusedWriteProperties;
    HRESULT (STDMETHODCALLTYPE *put_QueryMaxResults)(STSearchQueryHelper *, LONG);
} STSearchQueryHelperVtbl;
struct STSearchQueryHelper { const STSearchQueryHelperVtbl *lpVtbl; };
_Static_assert(offsetof(STSearchManagerVtbl, GetCatalog) == 10 * sizeof(void *), "Search manager SDK slot");
_Static_assert(offsetof(STSearchCatalogManagerVtbl, GetQueryHelper) == 25 * sizeof(void *), "Search catalog SDK slot");
_Static_assert(offsetof(STSearchQueryHelperVtbl, GenerateSQLFromUserQuery) == 20 * sizeof(void *), "Search query SDK slot");
_Static_assert(offsetof(STSearchQueryHelperVtbl, put_QueryMaxResults) == 22 * sizeof(void *), "Search limit SDK slot");
