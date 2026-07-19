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
  publicNavigation: read("app/navigation/publicNavigation.ts"),
  adminNavigation: read("app/navigation/adminNavigation.ts"),
  nextConfig: read("next.config.ts"),
  canonicalAdminPage: read("app/admin/[[...slug]]/page.tsx"),
  virtualPrice: readSourceText("app/virtual-price"),
  portfolio: readSourceText("app/portfolio"),
  reports: readSourceText("app/reports"),
  supplyDemand: readSourceText("app/supply-demand"),
  supplyDemandChart: read("app/supply-demand/MarketChartPanel.tsx"),
  supplyDemandOrders: readSourceText("app/supply-demand/orders"),
  supplyDemandAdmin: supplyDemandAdminSourceText,
  corporateActionDraftState: read("app/supply-demand/admin/useAdminStockEventDraftState.ts"),
  corporateActionForm: read("app/supply-demand/admin/AdminCorporateActionFormPanel.tsx"),
  corporateActionPayload: read("app/supply-demand/admin/AdminCorporateActionPayloadHelpers.ts"),
  supplyDemandAdminConstants: read("app/supply-demand/admin/AdminConstants.ts"),
  autoParticipantMutationPayload: read("app/supply-demand/admin/AdminAutoParticipantMutationPayloadHelpers.ts"),
  supplyDemandAdminAccountsSection: read("app/supply-demand/admin/AdminAccountsSection.tsx"),
  supplyDemandAdminAutomationSection: read("app/supply-demand/admin/AdminAutomationSection.tsx"),
  login: readSourceText("app/login"),
  authCallback: read("app/auth/callback/page.tsx"),
  authRouting: read("app/lib/authRouting.ts"),
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

const listingAutoInstitutionPolicyFields = [
  "targetBuyQuantity",
  "targetSellQuantity",
  "targetHoldingQuantity",
  "inventoryBandQuantity",
  "목표 보유 수량 맞춤",
  "전체 발행량 대비 목표 보유 비율",
  "MAX_LISTING_AUTO_NEW_ORDERS_PER_SIDE_PER_RUN",
  "필요 주문 조각",
  "위·아래 무작위(비교차)",
  "maximumSymmetricBand",
  "setPositionSide(\"TWO_SIDED\")",
  "보유 허용 밴드",
  "유효 호가",
  "openBuyQuantity",
  "openSellQuantity",
  "buyPriceOffsetDirection",
  "sellPriceOffsetDirection",
  "TWO_SIDED",
  "RANDOM",
];

const supplyDemandBatchJobNames = [
  "auto-market",
  "auto-market-order-expiry",
  "auto-participant-cash-flow",
  "corporate-actions",
  "listing-auto-market",
  "order-book-execution",
  "portfolio-settlement",
];
const frontBatchRuntimeLabels = parseObjectKeys(files.supplyDemandAdminConstants, "BATCH_JOB_RUNTIME_LABELS");
const recurringCashIntervalOptions = parseOptionValues(
  files.supplyDemandAdminConstants,
  "RECURRING_CASH_INTERVAL_UNIT_OPTIONS",
);
const listingAutoFragmentLimits = [
  parseIntegerConstant(
    readWorkspace("stock-batch-service/src/main/java/stock/batch/service/automarket/biz/ListingAutoAccountOrderService.java"),
    "MAX_NEW_ORDERS_PER_SIDE_PER_RUN",
  ),
  parseIntegerConstant(
    readWorkspace("stock-back-service/src/main/java/stock/back/service/market/biz/ListingAutoAccountConfigValidator.java"),
    "MAX_NEW_ORDERS_PER_SIDE_PER_RUN",
  ),
  parseIntegerConstant(files.supplyDemandAdminConstants, "MAX_LISTING_AUTO_NEW_ORDERS_PER_SIDE_PER_RUN"),
];

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
    "autoParticipantOverviews: (options?: { activityScope?: string; includeHoldings?: boolean; userKeys?: string[] })",
    "[...(options?.userKeys ?? [])].sort(),",
  ]) && !files.queryLayer.includes("[...(options?.userKeys ?? [])].sort().join(\",\")")],
  ["root page routes to primary stock pages", includesAll(files.home, [
    "/trade",
    "/portfolio",
    "/admin/participants/list",
    "자동참여자 수익률로 보는 모의 주식시장",
    "내 주식",
    "수요와 공급 주문 체결",
  ]) && includesAll(files.publicNavigation, [
    'href: "/trade"',
    'href: "/orders"',
    'href: "/portfolio"',
    'href: "/research"',
    'href: "/corporate-actions"',
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
  ["login page starts stock OAuth through the configured auth API", includesAll(files.login, [
    'onOAuthLogin("naver-stock")',
    'onOAuthLogin("kakao-stock")',
    "rememberOAuthNextPath(nextPath)",
    "`${AUTH_API_BASE}/oauth2/authorize/${provider}`",
  ])],
  ["stock OAuth callback restores the cookie-backed session without accepting URL tokens", includesAll(files.authCallback, [
    "window.history.replaceState",
    "ensureAccessToken()",
    "getUserFromToken(token)",
    "isStockAccountRole(user?.role)",
  ]) && !includesAny(files.authCallback, [
    "window.location.hash",
    'get("token")',
    "setAccessToken(",
  ])],
  ["login and OAuth callback return only to a sanitized internal path", includesAll(files.login + files.authCallback + files.authRouting, [
    "sanitizeAuthNextPath(searchParams.get(\"next\"))",
    "rememberOAuthNextPath(nextPath)",
    "router.replace(nextPath)",
    "router.replace(consumeOAuthNextPath())",
    "resolved.origin !== INTERNAL_ORIGIN",
    "window.sessionStorage.removeItem(OAUTH_NEXT_SESSION_KEY)",
  ])],
  ["stock account role guard allows USER and ADMIN", includesAll(files.login + files.authApi, ["isStockAccountRole", "UNSUPPORTED_ROLE_MESSAGE", "ADMIN"])],
  ["market APIs are wired", includesAll(files.stockApi, [
    "/api/stock/v1/markets/instruments",
    "/api/stock/v1/markets/prices",
    "/api/stock/v1/markets/prices/",
    "/api/stock/v1/markets/order-books/",
    "/api/stock/v1/markets/rankings",
    "/api/stock/v1/markets/order-book-instruments/",
    "/market-report",
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
  ["snapshot corporate actions require a future ex-rights date", countOccurrences(files.corporateActionDraftState, "exRightsDate: nextDate") === 3
    && files.corporateActionDraftState.includes("subscriptionStartDate: secondDate")
    && files.corporateActionForm.includes("const exRightsMinDate = addIsoDateDays(currentSimulationDate, 1);")
    && includesAll(files.corporateActionPayload, [
      'validateSnapshotDateAfterCurrent(\n      "배당락일"',
      'validateSnapshotDateAfterCurrent(\n          "주주배정 권리락일"',
      'validateSnapshotDateAfterCurrent(\n        "권리락일"',
      "if (value <= currentSimulationDate)",
    ])],
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
  ["public instrument market reports are wired", includesAll(files.stockApi + files.types + files.reports, [
    "InstrumentMarketReport",
    "getInstrumentMarketReport",
    "instrumentMarketReportQueryOptions",
    "marketCapitalization",
    "tradableMarketCapitalization",
    "종목 보고서",
    "시가총액",
    "turnoverRate",
    "InstrumentMarketAnalytics",
    "reportDate",
    "closePrice",
    "return5Days",
    "dailyVolatility20Days",
    "averageTurnover20Days",
    "tradingActivity",
    "executionCount20Days",
    "executionQuantity20Days",
    "investorFlow",
    "topFiveHolderRate",
    "buySellRatio",
    "beforeIssuedShares",
    "afterIssuedShares",
    "similarMarketCapitalizationPeers",
    "dataQuality",
    "가격 성과와 위험",
    "거래활동과 체결 빈도",
    "참가자 유형별 수급",
    "마감 시점 주식 수와 보유 구조",
    "기준일까지 공시된 기업 이벤트",
    "시장 내 순위와 비교",
    "데이터 기준과 신뢰 상태",
  ]) && !includesAny(files.reports, [
    "현재 호가",
    "호가 깊이와 유동성",
    "매수 예상 슬리피지",
    "매도 예상 슬리피지",
    "현재 미체결 주문",
    "상장주관사 포지션",
  ])],
  ["auto participant profile config fields are wired", autoParticipantProfileConfigFields.every((field) => includesAll(files.types + files.stockApi + files.supplyDemandAdmin, [field]))],
  ["listing auto institutional policy fields are wired", listingAutoInstitutionPolicyFields.every((field) => includesAll(files.types + files.stockApi + files.supplyDemandAdmin, [field]))],
  ["listing auto fragment limit matches batch, back, and front", listingAutoFragmentLimits.every((value) => value > 0)
    && new Set(listingAutoFragmentLimits).size === 1],
  ["automation profile tab renders profile config panel", includesAll(files.supplyDemandAdmin + files.supplyDemandAdminAutomationSection, [
    'if (activeSection === "participants-profiles")',
    "<AdminProfilesSection",
    "profileConfigs={profileConfigs}",
    "editingProfileType={editingProfileType}",
    "selectedProfileConfig={selectedProfileConfig}",
    "onSubmit={onSubmitProfileConfig}",
  ]) && includesAll(files.adminNavigation, [
    'href: "/admin/participants/profiles"',
    'label: "프로필 정책"',
  ]) && !files.supplyDemandAdminAccountsSection.includes("<AdminProfilesSection")],
  ["admin auto market symbol defaults explain operational fields", includesAll(files.supplyDemandAdmin, [
    "종목별 자동장 압력 분포",
    "자동장 대상 종목",
    "자동 주문 생성",
    "주·보조 분포 편향(-100~100)",
    "주 랜덤 일일 적용 횟수",
    "당일 주 랜덤 총",
    "dailyApplicationCount",
    "preparedRegimeSlotCount",
    "예상 평균",
    "1회 주문 최대 수량",
    "미체결 호가 TTL(초)",
    "stock_auto_market_config",
    "주 압력은 06시와 가중치로 선택된 추가 슬롯에서 하루 1~4회 갱신되고, 30분 보조 압력과 70:30으로 합성됩니다.",
    "return clampPressure(primary * 0.7 + secondary * 0.3);",
    "설정이 없으면 5이며 최신 보고서가 있으면 프로필 뉴스 민감도만큼 유효 강도가 보정됩니다.",
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
  ["admin asset summary separates money and holding metrics with selectable history", includesAll(files.types + files.supplyDemandAdmin, [
    "totalHoldingMarketValue",
    "totalHoldingQuantity",
    "totalReservedSellQuantity",
    "totalAvailableHoldingQuantity",
    "holdingPositionCount",
    "holdingQuantity: number | null",
    "reservedSellQuantity: number | null",
    "availableHoldingQuantity: number | null",
    "pendingSubscriptionAsset: number",
    "가용 현금",
    "주문·청약 대기금",
    "청약 대기자산",
    "보유 주식 평가액",
    "총 보유량",
    "가용 보유량",
    "총자산 구성 비중",
    "ADMIN_ASSET_HISTORY_METRIC_KEYS",
    "PENDING_SUBSCRIPTION_ASSET",
    "HOLDING_QUANTITY",
    "AVAILABLE_HOLDING_QUANTITY",
    "RESERVED_SELL_QUANTITY",
  ]) && !includesAny(files.supplyDemandAdmin, [
    'label="전체 현금"',
    'label="예약 매수 현금"',
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
    "activeAdminSection === \"participants-overview\"",
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
  ]) && includesAll(files.adminNavigation, [
    'href: "/admin/participants/overview"',
    'section: "participants-overview"',
  ])],
  ["profile-level overview query does not auto poll", includesAll(files.stockAdminQueries + files.supplyDemandAdmin, [
    "autoParticipantProfileOverviewsQueryOptions",
    "refetchInterval: options.refetchIntervalMs ?? false",
    "refetchIntervalMs: false",
    "onRefreshProfileOverviews",
  ])],
  ["EOD operations polling stays page-scoped and background-disabled", includesAll(files.stockAdminQueries + files.queryLayer + files.supplyDemandAdmin, [
    "eodOperationsOverviewQueryOptions",
    "ADMIN_EOD_REFETCH_MS = 15_000",
    'activeAdminSection === "system-eod"',
    "refetchIntervalInBackground: false",
    "refetchIntervalInBackground: config.refetchIntervalInBackground",
  ])],
  ["failed EOD phase retry stays current-cycle and control-plane-only", includesAll(files.stockApi + files.types + files.queryLayer + files.supplyDemandAdmin, [
    "EodPhaseRetryResult",
    "retryFailedEodPhase",
    "/api/stock/v1/markets/batch-jobs/eod/cycles/",
    'cycle?.status === "FAILED"',
    "현재 단계 재시도",
    "invalidateEodOperationsOverviewQuery",
    "다음 coordinator 판정에서 실행됩니다.",
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
  ["auto participant cash flow manual run stays inside shared batch runtime controls", includesAll(files.stockApi + files.types + files.supplyDemandAdmin + files.queryLayer, [
    "StockBatchJobRun",
    "runAutoParticipantCashFlow",
    "/api/stock/v1/markets/auto-market/cash-flow/run",
    "lastCashFlowRun",
    "latestManualCashFlowRunQueryOptions",
    'status === "QUEUED" || status === "PROCESSING"',
    "setLatestManualCashFlowRunQueryData(queryClient, cashFlowRunResult.data)",
    "invalidateLatestManualCashFlowRunQuery(queryClient)",
    "invalidateBatchRuntimeControlQueries(queryClient)",
    "resolveBatchManualAction",
    'jobName === "auto-participant-cash-flow"',
    "자동 월급 지급이 꺼져 있을 때만",
  ])],
  ["supply-demand admin sections are route-based pages", includesAll(files.supplyDemandAdmin, [
    "usePathname",
    "resolveAdminTabFromPath",
    "resolveAdminSectionFromPath",
    "AdminSidebarNavigation",
    "filterAutoParticipants",
    "selectedAutoParticipantSymbolConfigs",
    "visibleParticipantUserKeys",
    "참여자 검색",
    "aria-current",
  ]) && includesAll(files.adminNavigation, [
    'href: "/admin/market/instruments"',
    'href: "/admin/funds/payroll"',
    'href: "/admin/participants/overview"',
    'href: "/admin/participants/list"',
    'href: "/admin/participants/profiles"',
    'href: "/admin/participants/symbols"',
    'href: "/admin/market/liquidity"',
    'href: "/admin/system/jobs"',
    'href: "/admin/corporate/actions"',
  ]) && !files.supplyDemandAdmin.includes("autoMarketSummaryQuery.data ?? status") && includesAll(files.canonicalAdminPage, [
    "import AdminPageClient from \"@/app/supply-demand/admin/AdminPageClient\"",
    "<AdminPageClient />",
  ]) && includesAll(files.nextConfig, [
    'source: "/supply-demand/admin"',
    'destination: "/admin"',
  ])],
  ["admin shows salary recipients from participant overview and recurring policy", includesAll(files.stockApi + files.types + files.supplyDemandAdmin, [
    "AutoParticipantOverview",
    "getAutoParticipantOverviews",
    "autoParticipantOverviewsQueryOptions",
    "salaryEligibleParticipantCount",
    "includeSalaryEligibility",
    "activeAdminSection === \"funds-payroll\"",
    "SalaryEligibilityPanel",
    "resolveSalaryEligibilityRows",
    "월급 지급 대상",
    "ACTIVE 계좌",
    "개별 미지급",
  ])],
  ["admin recurring cash settings allow day or longer intervals only",
    sameSet(recurringCashIntervalOptions, ["DAY", "MONTH", "YEAR"])
      && files.autoParticipantMutationPayload.includes('z.enum(["DAY", "MONTH", "YEAR"])')],
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
  ["portfolio page renders account, holdings, history, orders, executions", includesAll(files.portfolio, [
    "추정 총자산",
    "계좌 요약",
    "보유 종목",
    "매입금액",
    "평가손익",
    "수익률",
    "미체결 주문",
    "자산 이력",
    "최근 매수 금액",
  ])],
  ["portfolio page uses account and activity queries", includesAll(files.portfolio, [
    "portfolioQueryOptions",
    "holdingsQueryOptions",
    "profitSummaryQueryOptions",
    "portfolioSnapshotsQueryOptions",
    "ordersQueryOptions",
    "executionsQueryOptions",
  ])],
  ["portfolio page filters and sorts holdings", includesAll(files.portfolio, [
    "FILTERS",
    "SORTS",
    "filterAndSortHoldingRows",
    "평가금액",
    "수익",
    "손실",
    "예약",
  ])],
  ["order book supports LIMIT and MARKET order types", includesAll(files.supplyDemand, ['"LIMIT"', '"MARKET"', "지정가", "시장가"])],
  ["order book exposes BUY and SELL order sides", includesAll(files.supplyDemand, ['"BUY"', '"SELL"', "매수", "매도"])],
  ["order book exposes pending order cancellation", includesAll(files.supplyDemand + files.supplyDemandOrders, ["onCancel(order.id)", "cancelRemainingOrder", "cancellingOrderId", "취소"])],
  ["portfolio page shows settlement history", includesAll(files.portfolio, ["자산 이력", "AssetLineChart", "portfolioSnapshotsQueryOptions"])],
  ["order book shows price and volume history", includesAll(files.supplyDemand + files.supplyDemandChart, ["가격 흐름", "PRICE / VOLUME", "orderBookCandlesQueryOptions"])],
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

function readWorkspace(relativePath) {
  return readFileSync(join(root, relativePath), "utf8");
}

function parseIntegerConstant(source, constantName) {
  const match = source.match(new RegExp(`${constantName}\\s*=\\s*(\\d+)`));
  return match ? Number(match[1]) : Number.NaN;
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

function parseOptionValues(text, arrayName) {
  const match = text.match(new RegExp(`(?:export\\s+)?const\\s+${arrayName}[\\s\\S]*?=\\s*\\[([\\s\\S]*?)\\n\\];`));
  if (!match) {
    throw new Error(`${arrayName} options not found`);
  }
  return [...match[1].matchAll(/value:\s*"([^"]+)"/g)]
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
