#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const frontRoot = join(root, "stock-front-service");
const frontSourceText = readFrontendSourceText();

const files = {
  stockApi: read("app/lib/stock.ts"),
  authApi: read("app/lib/auth.ts"),
  home: read("app/page.tsx"),
  virtualPrice: read("app/virtual-price/page.tsx"),
  supplyDemand: read("app/supply-demand/page.tsx"),
  supplyDemandOrders: read("app/supply-demand/orders/page.tsx"),
  supplyDemandAdmin: read("app/supply-demand/admin/page.tsx"),
  supplyDemandAdminMarket: read("app/supply-demand/admin/market/page.tsx"),
  supplyDemandAdminAccounts: read("app/supply-demand/admin/accounts/page.tsx"),
  supplyDemandAdminAccountsSalary: read("app/supply-demand/admin/accounts/salary/page.tsx"),
  supplyDemandAdminAccountsParticipants: read("app/supply-demand/admin/accounts/participants/page.tsx"),
  supplyDemandAdminAutomation: read("app/supply-demand/admin/automation/page.tsx"),
  supplyDemandAdminAutomationSymbols: read("app/supply-demand/admin/automation/symbols/page.tsx"),
  supplyDemandAdminAutomationListingAuto: read("app/supply-demand/admin/automation/listing-auto/page.tsx"),
  supplyDemandAdminAutomationStrategies: read("app/supply-demand/admin/automation/strategies/page.tsx"),
  supplyDemandAdminAutomationBatch: read("app/supply-demand/admin/automation/batch/page.tsx"),
  supplyDemandAdminEvents: read("app/supply-demand/admin/events/page.tsx"),
  supplyDemandAdminLegacyParticipants: read("app/supply-demand/admin/participants/page.tsx"),
  login: read("app/login/page.tsx"),
  queryLayer: read("app/lib/react-query/stockQueries.ts"),
  mutationLayer: read("app/lib/react-query/stockMutations.ts"),
  apiLayer: read("app/lib/api.ts"),
  types: read("app/types/stock.ts"),
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
const frontBatchRuntimeLabels = parseObjectKeys(files.supplyDemandAdmin, "BATCH_JOB_RUNTIME_LABELS");

const checks = [
  ["strict TypeScript is enabled", files.tsconfig.compilerOptions?.strict === true],
  ["JavaScript source is disabled", files.tsconfig.compilerOptions?.allowJs === false],
  ["axios is used for API requests", hasDependency("axios") && files.apiLayer.includes("axios.create")],
  ["React Query is wired", hasDependency("@tanstack/react-query") && includesAll(files.virtualPrice + files.supplyDemand + files.queryLayer, ["useQuery", "queryOptions", "invalidateQueries"])],
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
    'marketType: "ORDER_BOOK"',
    'source: "INTERNAL_ORDER_BOOK"',
  ])],
  ["order book page selects symbol from loaded instruments", includesAll(files.supplyDemand, [
    "useStockUiStore",
    "setOrderBookTicket",
    "value={selectedSymbol}",
    "orderBookQueryOptions(selectedSymbol)",
  ]) && !files.supplyDemand.includes("?? instruments[0]")],
  ["order book admin selects newly created instrument for follow-up actions", includesAll(files.supplyDemandAdmin, [
    "createInstrumentSchema",
    "setActionSymbol(instrument.symbol)",
    "setCorporateActions([])",
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
    "setLastCashFlowRun(result.data)",
    "void loadBatchJobRuntimeControls(false)",
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
    'href: "/supply-demand/admin/accounts/participants"',
    'href: "/supply-demand/admin/automation"',
    'href: "/supply-demand/admin/automation/symbols"',
    'href: "/supply-demand/admin/automation/listing-auto"',
    'href: "/supply-demand/admin/automation/strategies"',
    'href: "/supply-demand/admin/automation/batch"',
    'href: "/supply-demand/admin/events"',
    "filterAutoParticipants",
    "filterParticipantSymbolConfigs",
    "참여자 검색",
    "전략 검색",
    "aria-current",
  ]) && includesAll(
    files.supplyDemandAdminMarket
      + files.supplyDemandAdminAccounts
      + files.supplyDemandAdminAccountsSalary
      + files.supplyDemandAdminAccountsParticipants
      + files.supplyDemandAdminAutomation
      + files.supplyDemandAdminAutomationSymbols
      + files.supplyDemandAdminAutomationListingAuto
      + files.supplyDemandAdminAutomationStrategies
      + files.supplyDemandAdminAutomationBatch
      + files.supplyDemandAdminEvents,
    [
    "import SupplyDemandAdminPage from \"../page\"",
    "export default SupplyDemandAdminPage",
    ],
  ) && includesAll(files.supplyDemandAdminAccountsSalary + files.supplyDemandAdminAccountsParticipants + files.supplyDemandAdminAutomationSymbols + files.supplyDemandAdminAutomationListingAuto + files.supplyDemandAdminAutomationStrategies + files.supplyDemandAdminAutomationBatch, [
    "import SupplyDemandAdminPage from \"../../page\"",
    "export default SupplyDemandAdminPage",
  ]) && includesAll(files.supplyDemandAdminLegacyParticipants, [
    "redirect",
    "/supply-demand/admin/accounts/participants",
  ])],
  ["admin shows salary recipients from participant overview and recurring policy", includesAll(files.stockApi + files.types + files.supplyDemandAdmin, [
    "AutoParticipantOverview",
    "getAutoParticipantOverviews",
    "autoParticipantOverviewsQueryOptions",
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
  ["order mutation APIs are wired", includesAll(files.stockApi, ["placeOrder", "cancelOrder", "postJson<Order>", "deleteJson<Order>"])],
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
  ["auth refresh retry wraps protected APIs", countOccurrences(files.stockApi, "withAuthRefresh(token") >= 7],
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
    "useStockUiStore",
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

function readFrontendSourceText() {
  return walkTextFiles(frontRoot)
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

function isFrontendTextFile(fileName) {
  return [".ts", ".tsx", ".js", ".jsx", ".mjs", ".json", ".css"].some((extension) => fileName.endsWith(extension));
}

function parseObjectKeys(text, objectName) {
  const match = text.match(new RegExp(`const\\s+${objectName}\\s*:[\\s\\S]*?=\\s*\\{([\\s\\S]*?)\\n\\};`));
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
