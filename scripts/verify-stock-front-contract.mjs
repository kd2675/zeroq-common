#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const frontRoot = join(root, "stock-front-service");
const frontSourceText = readFrontendSourceText();
const supplyDemandAdminSourceText = readAdminSourceText();

const files = {
  stockApi: readStockApiSourceText(),
  authApi: read("app/lib/auth.ts"),
  rootLayout: read("app/layout.tsx"),
  simulationTimeBadge: read("app/components/SimulationTimeBadge.tsx"),
  simulationTime: read("app/lib/simulationTime.ts"),
  home: read("app/page.tsx"),
  virtualPrice: readSourceText("app/virtual-price"),
  supplyDemand: readSourceText("app/supply-demand"),
  supplyDemandChart: read("app/supply-demand/MarketChartPanel.tsx"),
  supplyDemandOrders: readSourceText("app/supply-demand/orders"),
  supplyDemandAdmin: supplyDemandAdminSourceText,
  supplyDemandAdminConstants: read("app/supply-demand/admin/AdminConstants.ts"),
  supplyDemandAdminMarket: read("app/supply-demand/admin/market/page.tsx"),
  supplyDemandAdminAccounts: read("app/supply-demand/admin/accounts/page.tsx"),
  supplyDemandAdminAccountsSalary: read("app/supply-demand/admin/accounts/salary/page.tsx"),
  supplyDemandAdminAccountsProfiles: read("app/supply-demand/admin/accounts/profiles/page.tsx"),
  supplyDemandAdminAccountsParticipants: read("app/supply-demand/admin/accounts/participants/page.tsx"),
  supplyDemandAdminAutomation: read("app/supply-demand/admin/automation/page.tsx"),
  supplyDemandAdminAutomationSymbols: read("app/supply-demand/admin/automation/symbols/page.tsx"),
  supplyDemandAdminAutomationListingAuto: read("app/supply-demand/admin/automation/listing-auto/page.tsx"),
  supplyDemandAdminAutomationStrategies: read("app/supply-demand/admin/automation/strategies/page.tsx"),
  supplyDemandAdminAutomationBatch: read("app/supply-demand/admin/automation/batch/page.tsx"),
  supplyDemandAdminEvents: read("app/supply-demand/admin/events/page.tsx"),
  supplyDemandAdminLegacyParticipants: read("app/supply-demand/admin/participants/page.tsx"),
  supplyDemandAdminAccountsSection: read("app/supply-demand/admin/AdminAccountsSection.tsx"),
  supplyDemandAdminAutomationSection: read("app/supply-demand/admin/AdminAutomationSection.tsx"),
  login: readSourceText("app/login"),
  queryLayer: readSourceText("app/lib/react-query"),
  stockAdminQueries: read("app/lib/react-query/stockAdminQueries.ts"),
  mutationLayer: read("app/lib/react-query/stockMutations.ts"),
  apiLayer: read("app/lib/api.ts"),
  types: readSourceText("app/types"),
  zodFormSchemas: read("app/lib/validation/zodFormSchemas.ts"),
  accountRequired: readSourceText("app/account-required"),
  packageJson: JSON.parse(read("package.json")),
  tsconfig: JSON.parse(read("tsconfig.json")),
};

const initialCorporateActionTypes = [
  "INITIAL_ISSUE",
  "PAID_IN_CAPITAL_INCREASE",
  "ADDITIONAL_ISSUE",
  "STOCK_SPLIT",
  "CASH_DIVIDEND",
  "BONUS_ISSUE",
  "STOCK_DIVIDEND",
  "DELISTING",
];

const adminCorporateActionTypes = initialCorporateActionTypes.filter((type) => type !== "INITIAL_ISSUE");
const deferredCorporateActionTypes = [
  "SPECIAL_DIVIDEND",
  "CAPITAL_REDUCTION",
  "REVERSE_SPLIT",
  "RIGHTS_OFFERING",
  "MERGER",
  "SPIN_OFF",
];

const autoParticipantProfileConfigFields = [
  "orderMultiplier",
  "aggressionMultiplier",
  "orderTtlMultiplier",
  "quantityMultiplier",
  "holdingPatienceWeight",
  "deepLossHoldWeight",
  "profitTakingWeight",
  "recurringDepositAmount",
  "recurringDepositIntervalValue",
  "recurringDepositIntervalUnit",
];

const supplyDemandBatchJobNames = [
  "auto-market",
  "auto-participant-cash-flow",
  "corporate-actions",
  "order-book-execution",
  "portfolio-settlement",
];
const frontBatchRuntimeLabels = parseObjectKeys(files.supplyDemandAdminConstants, "BATCH_JOB_RUNTIME_LABELS");

const checks = [
  ["strict TypeScript is enabled", files.tsconfig.compilerOptions?.strict === true],
  ["unused TypeScript locals and parameters fail the build", files.tsconfig.compilerOptions?.noUnusedLocals === true && files.tsconfig.compilerOptions?.noUnusedParameters === true],
  ["JavaScript source is disabled", files.tsconfig.compilerOptions?.allowJs === false],
  ["fetch is used through the shared API client", !hasDependency("axios") && includesAll(files.apiLayer, ["fetch(", "requestJson", "DEFAULT_REQUEST_TIMEOUT_MS"])],
  ["React Query is wired", hasDependency("@tanstack/react-query") && includesAll(files.virtualPrice + files.supplyDemand + files.queryLayer, ["useQuery", "queryOptions", "invalidateQueries"])],
  ["React Query cache writes stay inside centralized cache update module", includesAll(files.queryLayer, [
    "setBatchRuntimeControlQueryData",
    "applyPriceStreamEventQueryData",
    "queryClient.setQueryData",
  ]) && sameSet(findFrontendFilesContaining(/\bqueryClient\.setQueryData\b|\bsetQueryData</), [
    "app/lib/react-query/stockCacheUpdates.ts",
  ])],
  ["React Query cache invalidation and removal stay inside centralized invalidation module", includesAll(files.queryLayer, [
    "clearStockQueryCache",
    "invalidateAccountQueries",
    "invalidateOrderBookTradingQueries",
    "queryClient.clear",
    "queryClient.invalidateQueries",
    "queryClient.removeQueries",
  ]) && sameSet(findFrontendFilesContaining(/\bqueryClient\.(clear|invalidateQueries|removeQueries)\b/), [
    "app/lib/react-query/stockInvalidations.ts",
  ])],
  ["simulation time is visible on every page", includesAll(files.rootLayout + files.simulationTimeBadge + files.simulationTime, [
    "<SimulationTimeBadge />",
    "SIM TIME",
    "시뮬레이션 1일 = 실제",
    "realSecondsPerSimulationDay",
    "simulationClockQueryOptions",
    "createSimulationTimeSnapshot",
  ])],
  ["auto participant overview query key preserves user key array", includesAll(files.queryLayer, [
    "autoParticipantOverviews: (options?: { includeHoldings?: boolean; userKeys?: string[] })",
    "[...(options?.userKeys ?? [])].sort(),",
  ]) && !files.queryLayer.includes("[...(options?.userKeys ?? [])].sort().join(\",\")")],
  ["root page routes to separated market pages", includesAll(files.home, [
    "/virtual-price",
    "/supply-demand",
    "특정가격 자동주문체결",
    "수요와 공급 주문 체결",
  ])],
  ["frontend uses configured API base", files.apiLayer.includes("STOCK_CLIENT_ID") && files.apiLayer.includes("STOCK_API_BASE")],
  ["frontend does not call stock-batch internal API directly", !includesAny(frontSourceText, [
    "/internal/stock-batch",
    "localhost:20481",
    "127.0.0.1:20481",
    ":20481",
    "STOCK_BATCH_API",
    "NEXT_PUBLIC_STOCK_BATCH",
  ])],
  ["frontend does not expose stale fixture symbols", !includesAny(frontSourceText, [
    "ZQ001",
    "admin-ui-check",
  ])],
  ["login calls local auth API", includesAll(files.authApi, ["/auth/login", "/auth/refresh", "/auth/logout"])],
  ["signup uses auth user API", files.authApi.includes('"/api/users"') && files.authApi.includes('role: "USER"')],
  ["login form uses schema-based form validation", includesAll(files.login, [
    "useForm<LoginFormValues, unknown, LoginFormPayload>",
    "zodResolver(loginFormSchema)",
    "useWatch({ control: loginForm.control",
    "loginForm.handleSubmit",
    "loginFormSchema = z.object",
  ]) && !files.login.includes("validateLoginForm(")],
  ["account reconnect form uses schema-based validation", includesAll(files.accountRequired, [
    "useForm<ReconnectAccountFormValues, unknown, ReconnectAccountPayload>",
    "zodResolver(reconnectAccountSchema)",
    "useWatch({ control: reconnectForm.control",
    "reconnectForm.handleSubmit",
    "reconnectAccountSchema = z.object",
  ]) && !files.accountRequired.includes("if (!reconnectAccountCode.trim() || !reconnectRecoveryCode.trim())")],
  ["admin payload validation reuses shared Zod form primitives", includesAll(files.zodFormSchemas, [
    "requiredTrimmedString",
    "requiredUppercaseString",
    "optionalTrimmedStringAsUndefined",
    "optionalTrimmedStringAsNull",
    "positiveNumber",
    "positiveInteger",
    "nonNegativeInteger",
    "integerRange",
    "numberFromBlankZero",
  ]) && includesAll(files.supplyDemandAdmin, [
    "requiredUppercaseString",
    "numberFromBlankZero",
    "integerRange",
    "positiveInteger",
  ]) && !includesAny(files.supplyDemandAdmin, [
    "z.coerce.number()",
    ".transform((value) => value.toUpperCase())",
    ".transform((value) => value || undefined)",
    ".transform((value) => value || null)",
    "nextValue === \"\" ? 0 : Number(nextValue)",
    "value === \"\" ? 0 : Number(value)",
  ])],
  ["login page has stock OAuth entries", includesAll(files.login, ["/oauth2/authorize/naver-stock", "/oauth2/authorize/kakao-stock"])],
  ["login redirects all supported users to root", countOccurrences(files.login, 'router.replace("/")') >= 2 && !files.login.includes('router.replace("/virtual-price")') && !files.login.includes('router.replace("/supply-demand/admin")')],
  ["stock account role guard allows USER and ADMIN", includesAll(files.login + files.authApi, ["isStockAccountRole", "UNSUPPORTED_ROLE_MESSAGE", "ADMIN"])],
  ["market APIs are wired", includesAll(files.stockApi, [
    "/api/stock/v1/markets/instruments",
    "/api/stock/v1/markets/prices",
    "/api/stock/v1/markets/prices/",
    "/api/stock/v1/markets/order-books/",
    "/api/stock/v1/markets/rankings",
    "/api/stock/v1/markets/order-book-instruments/",
    "/reports",
  ])],
  ["protected stock APIs are wired", includesAll(files.stockApi, [
    "/api/stock/v1/users/me",
    "/api/stock/v1/portfolio/me",
    "/api/stock/v1/portfolio/me/snapshots",
    "/api/stock/v1/orders",
    "/api/stock/v1/executions",
    "/api/stock/v1/holdings",
  ])],
  ["order book activity uses server-side filters", includesAll(files.stockApi + files.supplyDemand, [
    "toQuery",
    "marketType",
    "source",
    "limit",
    'marketType: "ORDER_BOOK"',
    'source: "INTERNAL_ORDER_BOOK"',
    "symbol: selectedSymbol",
    "ACTIVITY_PREVIEW_LIMIT",
  ])],
  ["order book page selects symbol from loaded instruments", includesAll(files.supplyDemand, [
    "useOrderBookTicketState",
    "setOrderBookTicket",
    "value={selectedSymbol}",
    "orderBookQueryOptions(selectedSymbol",
  ]) && !files.supplyDemand.includes("?? instruments[0]")],
  ["order book trading screen keeps depth above chart", includesAll(files.supplyDemand + files.supplyDemandChart, [
    "<OrderBookDepthPanel",
    "<MarketChartPanel",
    "ORDER BOOK DEPTH",
    "PRICE / VOLUME",
  ]) && appearsBefore(files.supplyDemand, "<OrderBookDepthPanel", "<MarketChartPanel")],
  ["order book chart supports expandable interactive candlesticks", includesAll(files.supplyDemand + files.supplyDemandChart, [
    "lightweight-charts",
    "createChart",
    "CandlestickSeries",
    "HistogramSeries",
    "chartExpanded",
    "onExpandedChange",
    "확대",
    "축소",
    "handleScale",
    "mouseWheel: true",
    "pinch: true",
  ])],
  ["stacked order book uses centered price ladder", includesAll(files.supplyDemand, [
    "StackedOrderBookRow",
    "매도 잔량",
    "매수 잔량",
    "중앙 현재가",
    "매도 위 / 매수 아래",
    "sortAskLevels",
    "sortBidLevels",
    "stackedAsks: [...fixedAsks].reverse()",
    "stackedBids: fixedBids",
  ])],
  ["order book admin selects newly created instrument for follow-up actions", includesAll(files.supplyDemandAdmin + files.queryLayer, [
    "createInstrumentSchema",
    "setActionSymbol(instrument.symbol)",
    "reportSymbolRef.current = instrument.symbol",
    "setReportSymbol(instrument.symbol)",
    "stockKeys.orderBook(symbol)",
  ])],
  ["corporate actions stay within initial project scope", includesAll(files.types, initialCorporateActionTypes)
    && includesAll(files.supplyDemandAdmin, adminCorporateActionTypes)
    && !includesAny(files.types + files.supplyDemandAdmin, deferredCorporateActionTypes)],
  ["instrument report admin flow is wired", includesAll(files.stockApi + files.types + files.supplyDemandAdmin, [
    "InstrumentReport",
    "getInstrumentReports",
    "publishInstrumentReport",
    "updateInstrumentReport",
    "deleteInstrumentReport",
    "종목 평가 보고서",
    "상승 이유",
    "하락 이유",
  ])],
  ["auto participant profile config fields are wired", autoParticipantProfileConfigFields.every((field) => includesAll(files.types + files.stockApi + files.supplyDemandAdmin, [field]))],
  ["automation profile tab renders profile config panel", includesAll(files.supplyDemandAdmin + files.supplyDemandAdminAutomationSection, [
    'href: "/supply-demand/admin/automation"',
    'label: "프로필"',
    'if (activeSection === "profiles")',
    "<AdminProfilesSection",
    "profileConfigs={profileConfigs}",
    "editingProfileType={editingProfileType}",
    "selectedProfileConfig={selectedProfileConfig}",
    "onSubmit={onSubmitProfileConfig}",
  ]) && !files.supplyDemandAdminAccountsSection.includes("<AdminProfilesSection")],
  ["admin auto market symbol defaults explain operational fields", includesAll(files.supplyDemandAdmin, [
    "종목별 자동장 기본값",
    "자동장 대상 종목",
    "자동 주문 생성",
    "기본 방향 강도(1-10)",
    "1회 주문 최대 수량",
    "미체결 호가 TTL(초)",
    "stock_auto_market_config",
    "실제 주문은 종목 기본값, 참여자별 종목 전략, 심리 프로필, 보고서 점수, 계좌 상태를 함께 계산해 생성됩니다.",
    "참여자별 종목 전략이 있으면 그 값이 우선 적용됩니다.",
    "예약 현금/수량을 돌려줍니다.",
  ])],
  ["admin cash ledger supports paged full view", includesAll(files.types + files.stockApi + files.supplyDemandAdmin, [
    "AdminCashFlowPage",
    "getAdminCashFlows",
    "/api/stock/v1/markets/admin/cash-flows",
    "전체 현금 원장",
    "페이지당",
    "hasPrevious",
    "hasNext",
    "onPageChange",
  ])],
  ["admin participant page shows per-participant portfolio overview", includesAll(files.supplyDemandAdmin, [
    "AutoParticipantOverviewDetail",
    "overviewByUserKey.get(participant.userKey)",
    "includeHoldings: true",
    "EMPTY_AUTO_PARTICIPANT_HOLDINGS",
    "<AutoParticipantOverviewDetail overview={overview} />",
    "resolveAutoParticipantHoldingPreview",
    "자동참가자 투자 현황",
    "자산과 손익",
    "보유와 평가",
    "거래와 활동",
    "개별 월급/현금",
    "탈퇴",
    "보유 평가액",
    "보유 종목 없음",
    "추정 총자산",
    "미실현손익",
    "순입금",
    "2시간 거래대금",
    "매수/매도 대기",
    "대기 수량",
    "최근 활동",
    "todayBuyQuantity",
    "todayGrossAmount",
    "openOrderCount",
    "openBuyQuantity",
    "openSellQuantity",
    "lastOrderAt",
    "lastExecutionAt",
  ]) && appearsBefore(files.supplyDemandAdmin, '<h2 className="text-base font-black">자동 참여자</h2>', "<AdminAutoParticipantCards")
    && !files.supplyDemandAdmin.includes("sticky top-0 z-20")
    && !files.supplyDemandAdmin.includes("sticky top-[var(--stock-admin-sticky-top)]")
    && !files.supplyDemandAdmin.includes("stock-admin-sticky-top")
    && !files.supplyDemandAdmin.includes("overflow-visible rounded-md border border-white/10")
    && !files.supplyDemandAdmin.includes("max-h-[72vh] overflow-auto")],
  ["admin account tab shows profile-level portfolio overview", includesAll(files.supplyDemandAdmin, [
    "ParticipantProfileOverviewPanel",
    "resolveParticipantProfileOverviewSummaries",
    'href: "/supply-demand/admin/accounts/profiles"',
    "activeAdminSection === \"profile-overview\"",
    "프로필별 자동참가자 현황",
    "ProfileMiniMetric",
    "ProfileOverviewInfoItem",
    "순입금",
    "손익/수익률",
    "주요 보유종목",
    "2시간 거래대금",
    "대기 매수/매도",
    "symbolHoldings",
    "enabledStrategyCount",
    "lastOrderAt",
    "lastExecutionAt",
  ]) && includesAll(files.supplyDemandAdminAccountsProfiles, [
    "import AdminPageClient from \"@/app/supply-demand/admin/AdminPageClient\"",
    "export default AdminPageClient",
  ]) && !files.supplyDemandAdmin.includes('activeAdminSection === "profile-overview"\n      || activeAdminSection === "profiles"')],
  ["profile-level overview query does not auto poll", includesAll(files.stockAdminQueries + files.supplyDemandAdmin, [
    "autoParticipantProfileOverviewsQueryOptions",
    "refetchInterval: options.refetchIntervalMs ?? false",
    "refetchIntervalMs: false",
    "onRefreshProfileOverviews",
  ])],
  ["batch runtime control APIs are wired", includesAll(files.stockApi + files.types + files.supplyDemandAdmin, [
    "BatchJobRuntimeStatus",
    "getBatchJobRuntimeControls",
    "updateBatchJobRuntimeControl",
    "/api/stock/v1/markets/batch-jobs/runtime-controls",
    "배치 자동 실행 제어",
    "formatRuntimeReason",
    "DB 런타임은 ON이지만 배치 서버 설정이 OFF라 자동 실행은 아직 스킵됩니다.",
    "배치 서버 설정이 OFF라 DB ON이어도 자동 실행하지 않습니다.",
  ])],
  ["auto participant cash flow manual run stays inside shared batch runtime controls", includesAll(files.stockApi + files.types + files.supplyDemandAdmin, [
    "StockBatchJobRun",
    "runAutoParticipantCashFlow",
    "/api/stock/v1/markets/auto-market/cash-flow/run",
    "lastCashFlowRun",
    "setLastCashFlowRun(cashFlowRunResult.data)",
    "invalidateBatchRuntimeControlQueries(queryClient)",
    "resolveBatchManualAction",
    'jobName === "auto-participant-cash-flow"',
    "자동 실행이 중지되어 있어도",
  ])],
  ["supply-demand admin sections are route-based pages", includesAll(files.supplyDemandAdmin, [
    "usePathname",
    "resolveAdminTabFromPath",
    "resolveAdminSectionFromPath",
    "AdminSubTabNav",
    'href: "/supply-demand/admin/market"',
    'href: "/supply-demand/admin/accounts"',
    'href: "/supply-demand/admin/accounts/salary"',
    'href: "/supply-demand/admin/accounts/profiles"',
    'href: "/supply-demand/admin/accounts/participants"',
    'href: "/supply-demand/admin/automation"',
    'href: "/supply-demand/admin/automation/symbols"',
    'href: "/supply-demand/admin/automation/listing-auto"',
    'href: "/supply-demand/admin/automation/batch"',
    'href: "/supply-demand/admin/events"',
    "filterAutoParticipants",
    "selectedAutoParticipantSymbolConfigs",
    "visibleParticipantUserKeys",
    "참여자 검색",
    "aria-current",
  ]) && !files.supplyDemandAdmin.includes("autoMarketSummaryQuery.data ?? status") && includesAll(
    files.supplyDemandAdminMarket
      + files.supplyDemandAdminAccounts
      + files.supplyDemandAdminAccountsSalary
      + files.supplyDemandAdminAccountsProfiles
      + files.supplyDemandAdminAccountsParticipants
      + files.supplyDemandAdminAutomation
      + files.supplyDemandAdminAutomationSymbols
      + files.supplyDemandAdminAutomationListingAuto
      + files.supplyDemandAdminAutomationBatch
      + files.supplyDemandAdminEvents,
    [
    "import AdminPageClient from \"@/app/supply-demand/admin/AdminPageClient\"",
    "export default AdminPageClient",
    ],
  ) && includesAll(files.supplyDemandAdminAccountsSalary + files.supplyDemandAdminAccountsProfiles + files.supplyDemandAdminAccountsParticipants + files.supplyDemandAdminAutomationSymbols + files.supplyDemandAdminAutomationListingAuto + files.supplyDemandAdminAutomationStrategies + files.supplyDemandAdminAutomationBatch, [
    "import AdminPageClient from \"@/app/supply-demand/admin/AdminPageClient\"",
    "export default AdminPageClient",
  ]) && includesAll(files.supplyDemandAdminLegacyParticipants + files.supplyDemandAdminAutomationStrategies, [
    "redirect",
    "/supply-demand/admin/accounts/participants",
  ])],
  ["admin shows salary recipients from participant overview and recurring policy", includesAll(files.stockApi + files.types + files.supplyDemandAdmin, [
    "AutoParticipantOverview",
    "getAutoParticipantOverviews",
    "autoParticipantOverviewsQueryOptions",
    "salaryEligibleParticipantCount",
    "includeSalaryEligibility",
    "activeAdminSection === \"salary\"",
    "SalaryEligibilityPanel",
    "resolveSalaryEligibilityRows",
    "월급 지급 대상",
    "ACTIVE 계좌",
    "개별 미지급",
  ])],
  ["batch runtime labels cover supply-demand batch jobs only", sameSet(supplyDemandBatchJobNames, frontBatchRuntimeLabels)
    && files.supplyDemandAdmin.includes("SUPPLY_DEMAND_BATCH_JOB_NAMES")
    && !files.supplyDemandAdmin.includes('"virtual-price-execution":')
    && !files.supplyDemandAdmin.includes('"market-data-refresh":')
    && !files.supplyDemandAdmin.includes('"market-close-rollover":')],
  ["order book market close runs from market symbol status", includesAll(files.stockApi + files.supplyDemandAdmin, [
    "updateMarketStatus",
    "/api/stock/v1/markets/${marketType}/symbols/${encodeURIComponent(symbol)}/status",
    "changeOrderBookMarketStatus",
    '<option value="CLOSED">마감</option>',
    "장마감을 실행했습니다.",
    "미체결 주문 정리",
    "예약 해제",
    "보유 스냅샷",
    "기준가 롤오버",
  ])],
  ["order mutation APIs are wired", includesAll(files.stockApi, ["placeOrder", "cancelOrder"])
    && includesAny(files.stockApi, ["postJson<Order>", "authenticatedPostJson<Order>"])
    && includesAny(files.stockApi, ["deleteJson<Order>", "authenticatedDeleteJson<Order>"])],
  ["order book has full my-orders page for open order cancellation", includesAll(files.stockApi + files.supplyDemand + files.supplyDemandOrders, [
    "/supply-demand/orders",
    "전체 보기",
    "내 주문 관리",
    "미체결 주문",
    "cancelOrderMutationOptions",
    "cancelOrderPartiallyMutationOptions",
    "잔량 전부 취소",
    "부분 취소",
    'marketType: "ORDER_BOOK"',
  ])],
  ["auth refresh retry wraps protected APIs", includesAll(files.stockApi, [
    "withAuthRefresh",
    "authenticatedGetJson",
    "authenticatedPostJson",
    "authenticatedPatchJson",
    "authenticatedDeleteJson",
  ]) && countOccurrences(files.stockApi, "authenticated") >= 7],
  ["dashboard renders portfolio, market, holdings, order book, rankings, orders, executions", includesAll(files.virtualPrice, [
    "총 자산",
    "시장 가격",
    "보유 종목",
    "주문장",
    "랭킹",
    "주문 입력",
    "주문 상태",
    "최근 체결",
  ])],
  ["dashboard selects symbol from loaded market data", includesAll(files.virtualPrice, [
    "useVirtualOrderTicketState",
    "resolveSelectedSymbol",
    "priceTicksQueryOptions(selectedSymbol)",
    "orderBookQueryOptions(selectedSymbol)",
  ]) && !files.virtualPrice.includes('useState("005930")')],
  ["dashboard supports LIMIT and MARKET order types", includesAll(files.virtualPrice, ['"LIMIT"', '"MARKET"', "지정가", "시장가"])],
  ["dashboard exposes BUY and SELL order sides", includesAll(files.virtualPrice, ['"BUY"', '"SELL"', "매수", "매도"])],
  ["dashboard exposes pending order cancellation", includesAll(files.virtualPrice, ["cancel(order.id)", "cancellingOrderId", "취소"])],
  ["dashboard shows settlement history", includesAll(files.virtualPrice, ["자산 기록", "PortfolioHistory", "장 마감 정산"])],
  ["dashboard shows price tick history", includesAll(files.virtualPrice, ["가격 흐름", "Sparkline", "priceTicksQueryOptions"])],
];

const failed = checks.filter(([, ok]) => !ok);

for (const [label, ok] of checks) {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}`);
}

if (failed.length) {
  console.error(`stock front contract failed: ${failed.length} check(s)`);
  process.exit(1);
}

console.log("stock front contract passed");

function read(relativePath) {
  return readFileSync(join(frontRoot, relativePath), "utf8");
}

function readSourceText(relativePath) {
  return walkTextFiles(join(frontRoot, relativePath))
    .map((filePath) => readFileSync(filePath, "utf8"))
    .join("\n");
}

function readStockApiSourceText() {
  return [
    read("app/lib/stock.ts"),
    readSourceText("app/lib/stock-api"),
  ].join("\n");
}

function readFrontendSourceText() {
  return walkTextFiles(frontRoot)
    .map((filePath) => readFileSync(filePath, "utf8"))
    .join("\n");
}

function readAdminSourceText() {
  return walkTextFiles(join(frontRoot, "app/supply-demand/admin"))
    .map((filePath) => readFileSync(filePath, "utf8"))
    .join("\n");
}

function walkTextFiles(directory) {
  return readdirSync(directory)
    .flatMap((entry) => {
      const path = join(directory, entry);
      if (entry === ".next" || entry === "node_modules") {
        return [];
      }
      if (statSync(path).isDirectory()) {
        return walkTextFiles(path);
      }
      return isFrontendTextFile(entry) ? [path] : [];
    });
}

function findFrontendFilesContaining(pattern) {
  return walkTextFiles(join(frontRoot, "app"))
    .filter((filePath) => pattern.test(readFileSync(filePath, "utf8")))
    .map((filePath) => relative(frontRoot, filePath))
    .sort();
}

function isFrontendTextFile(fileName) {
  return [".ts", ".tsx", ".js", ".jsx", ".mjs", ".json", ".css"].some((extension) => fileName.endsWith(extension));
}

function parseObjectKeys(text, objectName) {
  const match = text.match(new RegExp(`(?:export\\s+)?const\\s+${objectName}\\s*:[\\s\\S]*?=\\s*\\{([\\s\\S]*?)\\n\\};`));
  if (!match) {
    throw new Error(`${objectName} object not found`);
  }
  return [...match[1].matchAll(/"([^"]+)":\s*\{/g)]
    .map((matchItem) => matchItem[1])
    .sort();
}

function sameSet(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function includesAll(text, needles) {
  return needles.every((needle) => text.includes(needle));
}

function includesAny(text, needles) {
  return needles.some((needle) => text.includes(needle));
}

function appearsBefore(text, leftNeedle, rightNeedle) {
  const leftIndex = text.indexOf(leftNeedle);
  const rightIndex = text.indexOf(rightNeedle);
  return leftIndex >= 0 && rightIndex >= 0 && leftIndex < rightIndex;
}

function hasDependency(name) {
  return Boolean(files.packageJson.dependencies?.[name] || files.packageJson.devDependencies?.[name]);
}

function countOccurrences(text, needle) {
  let count = 0;
  let offset = 0;
  while (true) {
    const index = text.indexOf(needle, offset);
    if (index === -1) {
      return count;
    }
    count += 1;
    offset = index + needle.length;
  }
}
