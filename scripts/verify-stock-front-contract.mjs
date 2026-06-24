#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const frontRoot = join(root, "stock-front-service");

const files = {
  stockApi: read("app/lib/stock.ts"),
  authApi: read("app/lib/auth.ts"),
  home: read("app/page.tsx"),
  virtualPrice: read("app/virtual-price/page.tsx"),
  supplyDemand: read("app/supply-demand/page.tsx"),
  supplyDemandAdmin: read("app/supply-demand/admin/page.tsx"),
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
];

const adminCorporateActionTypes = initialCorporateActionTypes.filter((type) => type !== "INITIAL_ISSUE");
const deferredCorporateActionTypes = [
  "SPECIAL_DIVIDEND",
  "CAPITAL_REDUCTION",
  "REVERSE_SPLIT",
  "RIGHTS_OFFERING",
  "MERGER",
  "SPIN_OFF",
  "DELISTING",
];

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
    "resolveOrderBookSymbol",
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
  ["order mutation APIs are wired", includesAll(files.stockApi, ["placeOrder", "cancelOrder", "postJson<Order>", "deleteJson<Order>"])],
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
