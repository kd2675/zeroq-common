#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { basename, join, resolve } from "node:path";

const inputPath = process.argv[2];
if (!inputPath) {
  fail(
    "usage: node scripts/verify-stock-v4-baseline-artifact.mjs "
      + "<artifact-directory-or-baseline.ndjson.tsv>",
  );
}

const resolvedInput = resolve(inputPath);
const artifactFile = existsSync(resolvedInput) && statSync(resolvedInput).isDirectory()
  ? join(resolvedInput, "baseline.ndjson.tsv")
  : resolvedInput;
const checksumFile = join(resolve(artifactFile, ".."), "SHA256SUMS");

if (!existsSync(artifactFile)) {
  fail(`baseline artifact does not exist: ${artifactFile}`);
}
if (!existsSync(checksumFile)) {
  fail(`baseline checksum does not exist: ${checksumFile}`);
}

const artifactBuffer = readFileSync(artifactFile);
const expectedChecksum = readFileSync(checksumFile, "utf8")
  .trim()
  .split(/\s+/u)[0];
const actualChecksum = createHash("sha256").update(artifactBuffer).digest("hex");
assertEqual("artifact checksum", actualChecksum, expectedChecksum);

const rows = artifactBuffer
  .toString("utf8")
  .split(/\r?\n/u)
  .filter((line) => line.length > 0)
  .map(parseLine);

const expectedSectionCounts = new Map([
  ["META", 1],
  ["CLOSE_RUN", 1],
  ["POST_CLOSE_CYCLE", 1],
  ["DAILY_SYMBOL", 7],
  ["ACCOUNT_SNAPSHOT", 179],
  ["ACCOUNT_CASH_FLOW", 4649],
  ["HOLDING_SNAPSHOT", 395],
  ["CORPORATE_ACTION", 8],
  ["CORPORATE_ACTION_ENTITLEMENT", 72],
  ["AUTO_PARTICIPANT", 151],
  ["PROFILE_CONFIG", 27],
  ["AUTO_MARKET_CONFIG", 7],
  ["MARKET_PARTICIPANT", 7],
  ["PARTICIPANT_ACCOUNT", 27],
  ["UNDERWRITING_CONTRACT", 7],
  ["LIQUIDITY_MANDATE", 7],
  ["LIQUIDITY_TRANSITION", 7],
  ["SECURITY_ALLOCATION", 25],
  ["MARKET_REFERENCE_VOLUME", 14],
  ["UNDERWRITING_DAILY_STATE", 8],
  ["LIQUIDITY_DAILY_STATE", 41],
  ["INSTITUTION_PORTFOLIO", 4],
  ["INSTITUTION_MANDATE", 28],
  ["MARKET_POLICY", 32],
  ["AUTO_POLICY", 1],
  ["ORDER", 799],
  ["ORDER_STRATEGY_ORIGIN", 719],
  ["EXECUTION", 130],
  ["AUTO_INTENT", 16],
]);

const rowsBySection = new Map();
for (const row of rows) {
  const sectionRows = rowsBySection.get(row.section) ?? [];
  sectionRows.push(row);
  rowsBySection.set(row.section, sectionRows);
}

assertEqual(
  "section kind count",
  rowsBySection.size,
  expectedSectionCounts.size,
);
for (const [section, expectedCount] of expectedSectionCounts) {
  const sectionRows = rowsBySection.get(section) ?? [];
  assertEqual(`${section} row count`, sectionRows.length, expectedCount);
  const uniqueKeys = new Set(sectionRows.map((row) => row.key));
  assertEqual(`${section} unique key count`, uniqueKeys.size, expectedCount);
}

const metadata = singlePayload("META");
assertEqual("artifact version", metadata.artifactVersion, 6);
assertEqual("baseline close run id", metadata.baselineCloseRunId, 259);
assertEqual("baseline business date", metadata.baselineBusinessDate, "2027-02-09");
assertIncludes(
  "holding replay rule",
  metadata.holdingReplayRule,
  "reset reservedQuantity to zero",
);
assertIncludes(
  "cash replay rule",
  metadata.cashReplayRule,
  "postCancelCash",
);
assertIncludes(
  "operational replay rule",
  metadata.operationalReplayRule,
  "Preserve role ledgers",
);

const closeRun = singlePayload("CLOSE_RUN");
assertEqual("close run status", closeRun.status, "COMPLETED");
assertEqual("close run scope", closeRun.scope, "FULL");
assertEqual("close run cancelled order count", closeRun.cancelledOrderCount, 23);
assertEqual("close run holding snapshot count", closeRun.holdingSnapshotCount, 395);

const postCloseCycle = singlePayload("POST_CLOSE_CYCLE");
assertEqual("post-close cycle close run", postCloseCycle.closeRunId, 259);
assertEqual("post-close cycle status", postCloseCycle.status, "COMPLETED");

const dailyRows = payloads("DAILY_SYMBOL");
assertEqual("daily issued shares", sumInteger(dailyRows, "issuedShares"), 26_650_000n);
assertEqual(
  "daily tradable shares",
  sumInteger(dailyRows, "tradableShares"),
  19_325_000n,
);
assertEqual("daily BUY quantity", sumInteger(dailyRows, "buyQuantity"), 24_108n);
assertEqual(
  "daily turnover cents",
  sumMoneyCents(dailyRows, "turnoverAmount"),
  28_212_859_000n,
);
const dailyMarketCap = dailyRows.reduce(
  (total, row) => total
    + integer(row.closePrice) * integer(row.issuedShares),
  0n,
);
assertEqual("daily market capitalization", dailyMarketCap, 333_820_000_000n);

const accountRows = payloads("ACCOUNT_SNAPSHOT");
assertEqual(
  "account reconciliation mismatch count",
  accountRows.filter((row) => row.reconciliationStatus !== "MATCHED").length,
  0,
);
assertEqual(
  "post-cancel account cash cents",
  sumMoneyCents(accountRows, "postCancelCash"),
  28_853_738_248_400n,
);
assertEqual(
  "account holding market value cents",
  sumMoneyCents(accountRows, "holdingMarketValue"),
  33_382_000_000_000n,
);

const cashFlowRows = payloads("ACCOUNT_CASH_FLOW");
assertEqual(
  "account cash-flow minimum id",
  Math.min(...cashFlowRows.map((row) => row.id)),
  1,
);
assertEqual(
  "account cash-flow maximum id",
  Math.max(...cashFlowRows.map((row) => row.id)),
  4649,
);
const cashFlowNetCents = cashFlowRows.reduce((total, row) => {
  const amountCents = moneyCents(row.amount);
  if (row.flowType === "DEPOSIT") {
    return total + amountCents;
  }
  if (row.flowType === "WITHDRAW") {
    return total - amountCents;
  }
  fail(`unsupported account cash-flow type: ${String(row.flowType)}`);
}, 0n);
assertEqual(
  "account cash-flow signed net cents",
  cashFlowNetCents,
  28_853_738_248_400n,
);
assertEqual(
  "account cash-flow net equals post-cancel cash",
  cashFlowNetCents,
  sumMoneyCents(accountRows, "postCancelCash"),
);
assertEqual(
  "sanitized account cash-flow creator count",
  cashFlowRows.filter(
    (row) => row.replayCreatedBy === "REPLAY_BASELINE",
  ).length,
  cashFlowRows.length,
);

const holdingRows = payloads("HOLDING_SNAPSHOT");
assertEqual(
  "holding quantity",
  sumInteger(holdingRows, "quantity"),
  26_650_000n,
);
assertEqual(
  "snapshot reserved quantity",
  sumInteger(holdingRows, "snapshotReservedQuantity"),
  59_203n,
);
assertEqual(
  "replay reserved quantity",
  sumInteger(holdingRows, "replayReservedQuantity"),
  0n,
);

const dailyBySymbol = indexBy(dailyRows, "symbol");
const holdingsBySymbol = groupBy(holdingRows, "symbol");
for (const [symbol, daily] of dailyBySymbol) {
  const symbolHoldings = holdingsBySymbol.get(symbol) ?? [];
  assertEqual(
    `${symbol} holding quantity`,
    sumInteger(symbolHoldings, "quantity"),
    integer(daily.issuedShares),
  );
  assertEqual(
    `${symbol} holder count`,
    symbolHoldings.filter((row) => integer(row.quantity) > 0n).length,
    daily.holderCount,
  );
}

const autoParticipants = payloads("AUTO_PARTICIPANT");
assertEqual(
  "enabled engine participant count",
  autoParticipants.filter(
    (participant) => participant.enabled === 1 && participant.withdrawnAt === null,
  ).length,
  150,
);
for (const participant of autoParticipants) {
  if (participant.replayUserKey !== `REPLAY_AUTO_${participant.accountId}`) {
    fail(
      `auto participant replay key mismatch: account=${participant.accountId} `
        + `actual=${participant.replayUserKey}`,
    );
  }
}
console.log(`PASS auto participant replay keys = ${autoParticipants.length}`);

const profileConfigs = payloads("PROFILE_CONFIG");
assertEqual(
  "source V3 profile config count",
  profileConfigs.filter(
    (profile) => profile.sourceBehaviorModelVersion === "V3",
  ).length,
  27,
);
const configuredProfileTypes = new Set(
  profileConfigs.map((profile) => profile.profileType),
);
const participantProfileTypes = new Set(
  autoParticipants.map((participant) => participant.profileType),
);
assertEqual(
  "configured profile type count",
  configuredProfileTypes.size,
  27,
);
for (const profileType of participantProfileTypes) {
  if (!configuredProfileTypes.has(profileType)) {
    fail(`auto participant profile has no source config: ${profileType}`);
  }
}
console.log(
  `PASS participant profile coverage = ${participantProfileTypes.size}`,
);

const accountById = new Map(
  accountRows.map((account) => [String(account.accountId), account]),
);
const corporateActionRows = payloads("CORPORATE_ACTION");
const corporateActionById = indexBy(corporateActionRows, "id");
assertEqual(
  "corporate action minimum id",
  Math.min(...corporateActionRows.map((row) => row.id)),
  1,
);
assertEqual(
  "corporate action maximum id",
  Math.max(...corporateActionRows.map((row) => row.id)),
  8,
);
assertEqual(
  "initial issue corporate action count",
  corporateActionRows.filter((row) => row.actionType === "INITIAL_ISSUE").length,
  7,
);
assertEqual(
  "cash dividend corporate action count",
  corporateActionRows.filter((row) => row.actionType === "CASH_DIVIDEND").length,
  1,
);
for (const action of corporateActionRows) {
  if (!dailyBySymbol.has(action.symbol)) {
    fail(`corporate action symbol is missing from daily baseline: ${action.symbol}`);
  }
}
console.log("PASS corporate action symbol coverage");

const entitlementRows = payloads("CORPORATE_ACTION_ENTITLEMENT");
const entitlementById = indexBy(entitlementRows, "id");
for (const entitlement of entitlementRows) {
  assertReferencePresent(
    "corporate action entitlement action",
    corporateActionById,
    entitlement.actionId,
  );
  assertReferencePresent(
    "corporate action entitlement account",
    accountById,
    entitlement.accountId,
  );
  if (!dailyBySymbol.has(entitlement.symbol)) {
    fail(
      "corporate action entitlement symbol is missing from daily baseline: "
        + entitlement.symbol,
    );
  }
}
console.log("PASS corporate action entitlement references");

for (const cashFlow of cashFlowRows) {
  assertReferencePresent(
    "account cash-flow account",
    accountById,
    cashFlow.accountId,
  );
  if (cashFlow.corporateActionId !== null) {
    assertReferencePresent(
      "account cash-flow corporate action",
      corporateActionById,
      cashFlow.corporateActionId,
    );
  }
  if (cashFlow.corporateActionEntitlementId !== null) {
    assertReferencePresent(
      "account cash-flow entitlement",
      entitlementById,
      cashFlow.corporateActionEntitlementId,
    );
  }
}
console.log("PASS account cash-flow references");

const categoryQuantityBySymbol = new Map();
for (const holding of holdingRows) {
  const account = accountById.get(String(holding.accountId));
  if (!account) {
    fail(`holding account is missing from close snapshot: ${holding.accountId}`);
  }
  const key = `${account.participantCategory}:${holding.symbol}`;
  categoryQuantityBySymbol.set(
    key,
    (categoryQuantityBySymbol.get(key) ?? 0n) + integer(holding.quantity),
  );
}

const expectedUnderwriterQuantities = new Map([
  ["DEMO004", 4_974_998n],
  ["DEMO005", 1_492_500n],
  ["DEMO006", 621_875n],
  ["DEMO007", 198_999n],
]);
for (const [symbol, expectedQuantity] of expectedUnderwriterQuantities) {
  assertEqual(
    `${symbol} underwriter inventory`,
    categoryQuantityBySymbol.get(`ISSUE_UNDERWRITER:${symbol}`) ?? 0n,
    expectedQuantity,
  );
}

const expectedCustodyQuantities = new Map([
  ["DEMO004", 5_000_000n],
  ["DEMO005", 1_500_000n],
  ["DEMO006", 625_000n],
  ["DEMO007", 200_000n],
]);
for (const [symbol, expectedQuantity] of expectedCustodyQuantities) {
  assertEqual(
    `${symbol} custody inventory`,
    categoryQuantityBySymbol.get(`SYSTEM_CUSTODY:${symbol}`) ?? 0n,
    expectedQuantity,
  );
}

const autoMarketConfigs = payloads("AUTO_MARKET_CONFIG");
assertEqual(
  "enabled auto-market config count",
  autoMarketConfigs.filter((config) => config.enabled === 1).length,
  7,
);
const autoMarketConfigBySymbol = indexBy(autoMarketConfigs, "symbol");
for (const symbol of dailyBySymbol.keys()) {
  assertReferencePresent(
    "daily symbol auto-market config",
    autoMarketConfigBySymbol,
    symbol,
  );
}
console.log("PASS auto-market config symbol coverage");

const participantRows = payloads("MARKET_PARTICIPANT");
const participantById = indexBy(participantRows, "id");
const underwritingContracts = payloads("UNDERWRITING_CONTRACT");
const underwritingContractById = indexBy(underwritingContracts, "id");
const liquidityMandates = payloads("LIQUIDITY_MANDATE");
const liquidityMandateById = indexBy(liquidityMandates, "id");
const institutionPortfolios = payloads("INSTITUTION_PORTFOLIO");
const institutionPortfolioById = indexBy(institutionPortfolios, "id");

const liquidityTransitions = payloads("LIQUIDITY_TRANSITION");
assertEqual(
  "LIVE_ACTIVE liquidity transition count",
  liquidityTransitions.filter((transition) => transition.stage === "LIVE_ACTIVE")
    .length,
  7,
);
for (const transition of liquidityTransitions) {
  assertReferencePresent(
    "liquidity transition mandate",
    liquidityMandateById,
    transition.mandateId,
  );
  assertReferencePresent(
    "liquidity transition participant",
    participantById,
    transition.participantId,
  );
  for (const accountId of [
    transition.legacyAccountId,
    transition.sourceAccountId,
    transition.liquidityAccountId,
  ]) {
    if (accountId !== null) {
      assertReferencePresent(
        "liquidity transition account",
        accountById,
        accountId,
      );
    }
  }
}
console.log("PASS liquidity transition references");

const securityAllocations = payloads("SECURITY_ALLOCATION");
assertEqual(
  "security allocation quantity",
  sumInteger(securityAllocations, "quantity"),
  37_183_802n,
);
for (const allocation of securityAllocations) {
  if (allocation.sourceAccountId !== null) {
    assertReferencePresent(
      "security allocation source account",
      accountById,
      allocation.sourceAccountId,
    );
  }
  assertReferencePresent(
    "security allocation destination account",
    accountById,
    allocation.destinationAccountId,
  );
  if (allocation.corporateActionId !== null) {
    assertReferencePresent(
      "security allocation corporate action",
      corporateActionById,
      allocation.corporateActionId,
    );
  }
  if (allocation.underwritingContractId !== null) {
    assertReferencePresent(
      "security allocation underwriting contract",
      underwritingContractById,
      allocation.underwritingContractId,
    );
  }
}
console.log("PASS security allocation references");

for (const contract of underwritingContracts) {
  const contractInitialAllocations = securityAllocations.filter(
    (allocation) =>
      allocation.underwritingContractId === contract.id
      && allocation.eventType === "INITIAL_ISSUE",
  );
  assertEqual(
    `${contract.symbol} initial issue ledger quantity`,
    sumInteger(contractInitialAllocations, "quantity"),
    integer(contract.totalIssueQuantity),
  );
  assertEqual(
    `${contract.symbol} tradable initial issue ledger quantity`,
    sumInteger(
      contractInitialAllocations.filter(
        (allocation) => allocation.tradabilityStatus === "TRADABLE",
      ),
      "quantity",
    ),
    integer(contract.tradableAllocationQuantity),
  );
  assertEqual(
    `${contract.symbol} locked initial issue ledger quantity`,
    sumInteger(
      contractInitialAllocations.filter(
        (allocation) => allocation.tradabilityStatus === "LOCKED",
      ),
      "quantity",
    ),
    integer(contract.lockedAllocationQuantity),
  );
}

const referenceVolumeRows = payloads("MARKET_REFERENCE_VOLUME");
assertEqual(
  "latest market reference volume row count",
  referenceVolumeRows.filter(
    (row) => row.simulationTradeDate === "2027-02-09",
  ).length,
  7,
);
for (const referenceVolume of referenceVolumeRows) {
  if (!dailyBySymbol.has(referenceVolume.symbol)) {
    fail(
      "market reference volume symbol is missing from daily baseline: "
        + referenceVolume.symbol,
    );
  }
}
console.log("PASS market reference volume symbol coverage");

const underwritingDailyStates = payloads("UNDERWRITING_DAILY_STATE");
for (const dailyState of underwritingDailyStates) {
  assertReferencePresent(
    "underwriting daily state contract",
    underwritingContractById,
    dailyState.underwritingContractId,
  );
}
console.log("PASS underwriting daily state references");

const liquidityDailyStates = payloads("LIQUIDITY_DAILY_STATE");
for (const dailyState of liquidityDailyStates) {
  assertReferencePresent(
    "liquidity daily state mandate",
    liquidityMandateById,
    dailyState.mandateId,
  );
}
console.log("PASS liquidity daily state references");

const marketPolicies = payloads("MARKET_POLICY");
assertEqual(
  "active market policy count",
  marketPolicies.filter((policy) => policy.status === "ACTIVE").length,
  15,
);
assertEqual(
  "retired market policy count",
  marketPolicies.filter((policy) => policy.status === "RETIRED").length,
  17,
);
const policyByScopeKeyVersion = new Map(
  marketPolicies.map((policy) => [
    `${policy.policyScope}:${policy.scopeKey}:${policy.versionNo}`,
    policy,
  ]),
);
assertEqual(
  "market policy natural key count",
  policyByScopeKeyVersion.size,
  marketPolicies.length,
);
for (const mandate of payloads("LIQUIDITY_MANDATE")) {
  const policy = policyByScopeKeyVersion.get(
    `LIQUIDITY_MANDATE:${mandate.symbol}:${mandate.policyVersion}`,
  );
  if (!policy || policy.status !== "ACTIVE") {
    fail(`active LP policy is missing: ${mandate.symbol}/${mandate.policyVersion}`);
  }
}
for (const portfolio of payloads("INSTITUTION_PORTFOLIO")) {
  const policy = policyByScopeKeyVersion.get(
    "INSTITUTIONAL_PORTFOLIO:"
      + `${portfolio.portfolioCode}:${portfolio.policyVersion}`,
  );
  if (!policy || policy.status !== "ACTIVE") {
    fail(
      "active institution policy is missing: "
        + `${portfolio.portfolioCode}/${portfolio.policyVersion}`,
    );
  }
}
console.log("PASS active LP and institution policy linkage");

const autoPolicy = singlePayload("AUTO_POLICY");
assertEqual("source auto policy version", autoPolicy.policyVersion, 1);
assertEqual(
  "source auto policy model",
  autoPolicy.sourceBehaviorModelVersion,
  "V3",
);
assertEqual("source auto policy status", autoPolicy.status, "ACTIVE");
assertEqual("source auto policy runtime", autoPolicy.runtimeEnabled, 1);
assertEqual("source auto policy JSON model", autoPolicy.policyJson.model, "V3");

const orderRows = payloads("ORDER");
const orderById = indexBy(orderRows, "id");
const orderOriginRows = payloads("ORDER_STRATEGY_ORIGIN");
assertEqual(
  "institutional order origin count",
  orderOriginRows.filter(
    (origin) => origin.originType === "INSTITUTIONAL_INVESTOR",
  ).length,
  288,
);
assertEqual(
  "liquidity-provider order origin count",
  orderOriginRows.filter(
    (origin) => origin.originType === "LIQUIDITY_PROVIDER",
  ).length,
  351,
);
assertEqual(
  "issue-underwriter order origin count",
  orderOriginRows.filter(
    (origin) => origin.originType === "ISSUE_UNDERWRITER",
  ).length,
  80,
);
for (const origin of orderOriginRows) {
  assertReferencePresent("order origin order", orderById, origin.orderId);
  assertReferencePresent(
    "order origin participant",
    participantById,
    origin.participantId,
  );
  if (origin.portfolioId !== null) {
    assertReferencePresent(
      "order origin institution portfolio",
      institutionPortfolioById,
      origin.portfolioId,
    );
  }
  if (origin.liquidityMandateId !== null) {
    assertReferencePresent(
      "order origin liquidity mandate",
      liquidityMandateById,
      origin.liquidityMandateId,
    );
  }
  if (origin.underwritingContractId !== null) {
    assertReferencePresent(
      "order origin underwriting contract",
      underwritingContractById,
      origin.underwritingContractId,
    );
  }
}
console.log("PASS order strategy origin references");

const buyExecutions = payloads("EXECUTION").filter(
  (execution) => execution.side === "BUY",
);
assertEqual("BUY execution count", buyExecutions.length, 65);
assertEqual(
  "BUY execution quantity",
  sumInteger(buyExecutions, "quantity"),
  24_108n,
);
assertEqual(
  "BUY execution gross cents",
  sumMoneyCents(buyExecutions, "grossAmount"),
  28_212_859_000n,
);

const intentRows = payloads("AUTO_INTENT");
const activeIntents = intentRows.filter((intent) => intent.status === "ACTIVE");
assertEqual("baseline active intent count", activeIntents.length, 13);
assertEqual(
  "baseline active intent open quantity",
  sumInteger(activeIntents, "openQuantity"),
  54_283n,
);

for (const row of rows) {
  assertNoSensitiveKeys(row.payload, `${row.section}:${row.key}`);
}

console.log(
  "stock V4 baseline artifact verification passed: "
    + `${rows.length} rows, ${basename(artifactFile)}`,
);

function parseLine(line, index) {
  const firstTab = line.indexOf("\t");
  const secondTab = line.indexOf("\t", firstTab + 1);
  if (firstTab <= 0 || secondTab <= firstTab + 1) {
    fail(`invalid TSV structure at line ${index + 1}`);
  }
  const section = line.slice(0, firstTab);
  const key = line.slice(firstTab + 1, secondTab);
  const payloadText = line.slice(secondTab + 1);
  try {
    return {
      section,
      key,
      payload: JSON.parse(payloadText),
    };
  } catch (error) {
    fail(`invalid JSON at line ${index + 1}: ${error.message}`);
  }
}

function payloads(section) {
  return (rowsBySection.get(section) ?? []).map((row) => row.payload);
}

function singlePayload(section) {
  const sectionPayloads = payloads(section);
  assertEqual(`${section} singleton`, sectionPayloads.length, 1);
  return sectionPayloads[0];
}

function indexBy(values, key) {
  const indexed = new Map();
  for (const value of values) {
    const indexKey = String(value[key]);
    if (indexed.has(indexKey)) {
      fail(`duplicate ${key}: ${indexKey}`);
    }
    indexed.set(indexKey, value);
  }
  return indexed;
}

function groupBy(values, key) {
  const grouped = new Map();
  for (const value of values) {
    const groupKey = String(value[key]);
    const group = grouped.get(groupKey) ?? [];
    group.push(value);
    grouped.set(groupKey, group);
  }
  return grouped;
}

function sumInteger(values, key) {
  return values.reduce(
    (total, value) => total + integer(value[key]),
    0n,
  );
}

function sumMoneyCents(values, key) {
  return values.reduce(
    (total, value) => total + moneyCents(value[key]),
    0n,
  );
}

function integer(value) {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    fail(`expected safe integer, actual=${String(value)}`);
  }
  return BigInt(value);
}

function moneyCents(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    fail(`expected finite money value, actual=${String(value)}`);
  }
  const cents = Math.round(value * 100);
  if (!Number.isSafeInteger(cents)) {
    fail(`money cents exceed safe integer range, actual=${String(value)}`);
  }
  return BigInt(cents);
}

function assertNoSensitiveKeys(value, path) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) =>
      assertNoSensitiveKeys(entry, `${path}[${index}]`));
    return;
  }
  if (value === null || typeof value !== "object") {
    return;
  }
  for (const [key, nestedValue] of Object.entries(value)) {
    if (["userKey", "displayName", "recoveryCodeHash"].includes(key)) {
      fail(`sensitive key is not allowed in artifact: ${path}.${key}`);
    }
    assertNoSensitiveKeys(nestedValue, `${path}.${key}`);
  }
}

function assertIncludes(label, actual, expectedFragment) {
  if (typeof actual !== "string" || !actual.includes(expectedFragment)) {
    fail(`${label} expected to include ${expectedFragment}, actual=${String(actual)}`);
  }
  console.log(`PASS ${label}`);
}

function assertReferencePresent(label, indexedRows, reference) {
  if (!indexedRows.has(String(reference))) {
    fail(`${label} is missing: ${String(reference)}`);
  }
}

function assertEqual(label, actual, expected) {
  if (actual !== expected) {
    fail(`${label} expected=${String(expected)} actual=${String(actual)}`);
  }
  console.log(`PASS ${label} = ${String(actual)}`);
}

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}
