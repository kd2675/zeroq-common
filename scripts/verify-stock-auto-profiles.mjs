#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const v3RuntimeArtifacts = findV3RuntimeArtifacts();
if (v3RuntimeArtifacts.length) {
  console.log(
    `FAIL V3 runtime sources are removed (${v3RuntimeArtifacts.join(", ")})`,
  );
  process.exit(1);
}
console.log("PASS V3 runtime sources are removed");

const batchProfileBehaviorTexts = readProfileBehaviorTexts();
const batchPolicyText = read("stock-batch-service/src/main/java/stock/batch/service/automarket/v4/profile/V4ProfilePolicyCatalog.java");
const batchExecutionPolicyText = read("stock-batch-service/src/main/java/stock/batch/service/automarket/profile/ProfileExecutionPolicy.java");
const batchProfilePolicyText = read("stock-batch-service/src/main/java/stock/batch/service/automarket/profile/ProfilePolicy.java");
const batchFundingPolicyResolverText = read("stock-batch-service/src/main/java/stock/batch/service/automarket/biz/AutoParticipantFundingPolicyResolver.java");
const backProfileConfigDefaultsText = read("stock-back-service/src/main/java/stock/back/service/market/biz/AutoParticipantProfileConfigDefaults.java");
const canonicalBatchProfiles = parseJavaEnum(
  read("stock-batch-service/src/main/java/stock/batch/service/batch/automarket/model/AutoParticipantProfileType.java"),
);
const batchRuntimeTestText = [
  read("stock-batch-service/src/test/java/stock/batch/service/automarket/biz/AutoMarketServiceUnitTest.java"),
  read("stock-batch-service/src/test/java/stock/batch/service/automarket/biz/AutoParticipantCashFlowServiceTest.java"),
  read("stock-batch-service/src/test/java/stock/batch/service/automarket/biz/AutoParticipantFundingPolicyResolverTest.java"),
  read("stock-batch-service/src/test/java/stock/batch/service/automarket/v4/profile/V4ProfileRegistryContractTest.java"),
].join("\n");

const sources = {
  batchEnum: canonicalBatchProfiles,
  backEnum: parseJavaEnum(read("stock-back-service/src/main/java/stock/back/service/database/entity/AutoParticipantProfileType.java")),
  frontType: parseTypeUnion(read("stock-front-service/app/types/stockAutomation.ts"), "AutoParticipantProfileType"),
  frontOptions: parseFrontOptions(read("stock-front-service/app/lib/autoParticipantProfiles.ts")),
  frontBehaviorDescriptions: parseFrontBehaviorDescriptions(read("stock-front-service/app/lib/autoParticipantProfiles.ts")),
  batchBehaviorClasses: parseBehaviorClasses(batchProfileBehaviorTexts),
  batchPolicies: parseBatchPolicyProfiles(batchPolicyText),
  backDefaults: parseMapPuts(backProfileConfigDefaultsText, "defaults"),
  canonicalMysqlParticipantDdl: parseDdlConstraintProfiles(read("stock-back-service/src/main/resources/db/ddl/stock_all.sql"), "chk_stock_auto_participant_profile_type"),
  canonicalMysqlConfigDdl: parseDdlConstraintProfiles(read("stock-back-service/src/main/resources/db/ddl/stock_all.sql"), "chk_stock_auto_profile_config_type"),
  batchH2ParticipantDdl: parseDdlConstraintProfiles(read("stock-batch-service/src/main/resources/db/ddl/stock_h2.sql"), "chk_stock_auto_participant_profile_type"),
  batchH2ConfigDdl: parseDdlConstraintProfiles(read("stock-batch-service/src/main/resources/db/ddl/stock_h2.sql"), "chk_stock_auto_profile_config_type"),
  autoMarketSpec: parseMarkdownProfileTable(read("stock-back-service/docs/market-simulation/development-specs/06-auto-market.md")),
  batchRuntimeTests: parseRuntimeTestProfiles(
    batchRuntimeTestText,
    canonicalBatchProfiles,
  ),
};

const canonical = sources.batchEnum;
const batchExecutionPolicies = parseBatchExecutionPolicies(batchExecutionPolicyText, canonical);
const backExecutionPolicies = parseBackExecutionPolicies(backProfileConfigDefaultsText, canonical);
const checks = Object.entries(sources).map(([name, profiles]) => [
  name,
  sameSet(canonical, profiles),
  diff(canonical, profiles),
]);

for (const [name, ok, detail] of checks) {
  console.log(`${ok ? "PASS" : "FAIL"} ${name} matches batch enum${formatDiff(detail)}`);
}

const failed = checks.filter(([, ok]) => !ok);
if (failed.length) {
  console.error(`stock auto profile contract failed: ${failed.length} source(s) out of sync`);
  process.exit(1);
}

const profileDefaultMismatches = compareProfileConfigDefaults(
  parseBatchProfileConfigDefaults(batchPolicyText, batchExecutionPolicies),
  parseBackProfileConfigDefaults(backProfileConfigDefaultsText, backExecutionPolicies),
  canonical,
);
if (profileDefaultMismatches.length) {
  console.log(`FAIL profileConfigDefaults match batch policy (${profileDefaultMismatches.join("; ")})`);
  console.error("stock auto profile contract failed: profile config defaults are out of sync");
  process.exit(1);
}
console.log("PASS profileConfigDefaults match batch policy");

const missingBehaviorMarkers = profileBehaviorMarkerMismatches(batchRuntimeTestText, canonical);
if (missingBehaviorMarkers.length) {
  console.log(`FAIL profileBehaviorTests cover profile behavior (${missingBehaviorMarkers.join("; ")})`);
  console.error("stock auto profile contract failed: profile behavior tests are incomplete");
  process.exit(1);
}
console.log("PASS profileBehaviorTests cover profile behavior");
if (/ProfileFundingPolicy|recurringDeposit/.test(batchProfilePolicyText)
    || /recurringDeposit/.test(read("stock-back-service/src/main/java/stock/back/service/market/biz/ProfileConfigDefaults.java"))
    || !batchFundingPolicyResolverText.includes("NO_RECURRING_FUNDING")) {
  console.log("FAIL recurring deposit policy is coupled to ProfilePolicy");
  process.exit(1);
}
console.log("PASS recurring deposit policy is separated from ProfilePolicy");
console.log(`stock auto profile contract passed: ${canonical.length} profiles`);

function read(relativePath) {
  return readFileSync(join(root, relativePath), "utf8");
}

function findV3RuntimeArtifacts() {
  const explicitPaths = [
    "stock-back-service/src/main/java/stock/back/service/market/biz/AutoParticipantV3OperationsService.java",
    "stock-back-service/src/main/java/stock/back/service/market/vo/AutoParticipantV3OperationsResponse.java",
    "stock-back-service/src/main/java/stock/back/service/market/vo/AutoParticipantV3PolicyScheduleRequest.java",
    "stock-back-service/src/main/java/stock/back/service/market/vo/AutoParticipantV3RuntimeRequest.java",
    "stock-front-service/app/supply-demand/admin/AdminAutoParticipantV3OperationsPanel.tsx",
  ];
  const discovered = explicitPaths.filter((relativePath) =>
    existsSync(join(root, relativePath)));
  const v3RuntimeDirectory =
    "stock-batch-service/src/main/java/stock/batch/service/automarket/v3";
  if (existsSync(join(root, v3RuntimeDirectory))) {
    discovered.push(
      ...readdirSync(join(root, v3RuntimeDirectory))
        .filter((fileName) => fileName.endsWith(".java"))
        .map((fileName) => `${v3RuntimeDirectory}/${fileName}`),
    );
  }
  return discovered.sort();
}

function readProfileBehaviorTexts() {
  const profileDir =
    "stock-batch-service/src/main/java/stock/batch/service/automarket/v4/profile";
  return readdirSync(join(root, profileDir))
    .filter((fileName) =>
      fileName.endsWith("V4Behavior.java")
      && fileName !== "V4ProfileBehavior.java"
      && fileName !== "AbstractV4ProfileBehavior.java")
    .sort()
    .map((fileName) => ({
      fileName,
      text: read(`${profileDir}/${fileName}`),
    }));
}

function parseJavaEnum(text) {
  const match = text.match(/public enum AutoParticipantProfileType\s*\{([\s\S]*?);/);
  if (!match) {
    throw new Error("AutoParticipantProfileType enum body not found");
  }
  return match[1]
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

function parseTypeUnion(text, typeName) {
  const match = text.match(new RegExp(`export type ${typeName} =([\\s\\S]*?);`));
  if (!match) {
    throw new Error(`${typeName} union not found`);
  }
  return [...match[1].matchAll(/"([A-Z_]+)"/g)].map((matchItem) => matchItem[1]);
}

function parseFrontOptions(text) {
  return [...text.matchAll(/value:\s*"([A-Z_]+)"/g)].map((matchItem) => matchItem[1]);
}

function parseFrontBehaviorDescriptions(text) {
  return [...text.matchAll(/\{\s*value:\s*"([A-Z_]+)"[\s\S]*?behavior:\s*"[^"]+"/g)]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseMapPuts(text, mapName) {
  const escapedMapName = mapName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return [...text.matchAll(new RegExp(`${escapedMapName}\\.put\\(AutoParticipantProfileType\\.([A-Z_]+)`, "g"))]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseBehaviorClasses(sources) {
  return sources
    .map((source) => {
      const classMatch = source.text.match(
        /public final class \w+V4Behavior extends AbstractV4ProfileBehavior/,
      );
      const typeMatch = source.text.match(/super\(\s*AutoParticipantProfileType\.([A-Z_]+),/);
      if (!classMatch || !typeMatch) {
        throw new Error(`profile behavior contract not found: ${source.fileName}`);
      }
      return typeMatch[1];
    })
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseBatchPolicyProfiles(text) {
  return [...text.matchAll(/case\s+([A-Z_]+)\s*->\s*p\(/g)]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseBatchProfileConfigDefaults(text, executionPolicies) {
  const defaults = new Map();
  for (const match of text.matchAll(
    /case\s+([A-Z_]+)\s*->\s*p\(([\s\S]*?)\);/g,
  )) {
    const args = splitArguments(match[2]);
    const parsed = {
      newsWeight: parseJavaValue(args[0], text),
      momentumWeight: parseJavaValue(args[1], text),
      contrarianWeight: parseJavaValue(args[2], text),
      lossAversionWeight: parseJavaValue(args[3], text),
      herdingWeight: parseJavaValue(args[4], text),
      marketMakingWeight: parseJavaValue(args[5], text),
      overconfidenceWeight: parseJavaValue(args[6], text),
      profitTakingWeight: parseJavaValue(args[7], text),
      orderMultiplier: parseJavaValue(args[8], text),
      aggressionMultiplier: parseJavaValue(args[9], text),
      orderTtlMultiplier: parseJavaValue(args[10], text),
      noiseWeight: parseJavaValue(args[11], text),
      quantityMultiplier: parseJavaValue(args[12], text),
      panicSellWeight: parseJavaValue(args[13], text),
      dipBuyWeight: parseJavaValue(args[14], text),
      holdingPatienceWeight: parseJavaValue(args[15], text),
      deepLossHoldWeight: parseJavaValue(args[16], text),
      pricePressureSensitivity: parseJavaValue(args[17], text),
      recurringDepositAmount: 0,
      recurringDepositIntervalValue: 0,
      recurringDepositIntervalUnit: "DAY",
    };
    defaults.set(match[1], withExecutionPolicy(parsed, executionPolicies.get(match[1])));
  }
  return defaults;
}

function parseBackProfileConfigDefaults(text, executionPolicies) {
  const defaults = new Map();
  const pricePressureSensitivities = parseBackPricePressureSensitivities(text);
  for (const line of text.split("\n")) {
    const match = line.match(/defaults\.put\(AutoParticipantProfileType\.([A-Z_]+), profileDefaults\((.*)\)\);/);
    if (!match) {
      continue;
    }
    const args = splitArguments(match[2]);
    const parsed = {
      newsWeight: parseJavaValue(args[0], text),
      momentumWeight: parseJavaValue(args[1], text),
      contrarianWeight: parseJavaValue(args[2], text),
      lossAversionWeight: parseJavaValue(args[3], text),
      herdingWeight: parseJavaValue(args[4], text),
      marketMakingWeight: parseJavaValue(args[5], text),
      overconfidenceWeight: parseJavaValue(args[6], text),
      noiseWeight: parseJavaValue(args[7], text),
      panicSellWeight: parseJavaValue(args[8], text),
      dipBuyWeight: parseJavaValue(args[9], text),
      orderMultiplier: parseJavaValue(args[10], text),
      aggressionMultiplier: parseJavaValue(args[11], text),
      pricePressureSensitivity: pricePressureSensitivities.get(match[1]),
      orderTtlMultiplier: parseJavaValue(args[12], text),
      quantityMultiplier: parseJavaValue(args[13], text),
      holdingPatienceWeight: parseJavaValue(args[14], text),
      deepLossHoldWeight: parseJavaValue(args[15], text),
      profitTakingWeight: parseJavaValue(args[16], text),
      recurringDepositAmount: 0,
      recurringDepositIntervalValue: 0,
      recurringDepositIntervalUnit: "DAY",
    };
    defaults.set(match[1], withExecutionPolicy(parsed, executionPolicies.get(match[1])));
  }
  return defaults;
}

function parseBackPricePressureSensitivities(text) {
  const method = text.match(/private static double defaultPricePressureSensitivity[\s\S]*?return switch \(profileType\) \{([\s\S]*?)\n\s*};/);
  if (!method) {
    throw new Error("defaultPricePressureSensitivity switch not found");
  }
  const values = new Map();
  for (const match of method[1].matchAll(/case ([A-Z_, ]+) -> ([0-9.]+);/g)) {
    for (const profile of match[1].split(",").map((value) => value.trim())) {
      values.set(profile, Number(match[2]));
    }
  }
  return values;
}

function compareProfileConfigDefaults(batchDefaults, backDefaults, profiles) {
  const fields = [
    "newsWeight",
    "momentumWeight",
    "contrarianWeight",
    "lossAversionWeight",
    "herdingWeight",
    "marketMakingWeight",
    "overconfidenceWeight",
    "noiseWeight",
    "panicSellWeight",
    "dipBuyWeight",
    "orderMultiplier",
    "aggressionMultiplier",
    "pricePressureSensitivity",
    "orderTtlMultiplier",
    "quantityMultiplier",
    "holdingPatienceWeight",
    "deepLossHoldWeight",
    "profitTakingWeight",
    "decisionFrequencyMultiplier",
    "ordersPerDecisionMultiplier",
    "pricingMode",
    "exitMode",
    "inventoryMode",
    "recurringDepositAmount",
    "recurringDepositIntervalValue",
    "recurringDepositIntervalUnit",
  ];
  const mismatches = [];
  for (const profile of profiles) {
    const batchDefault = batchDefaults.get(profile);
    const backDefault = backDefaults.get(profile);
    if (!batchDefault || !backDefault) {
      mismatches.push(`${profile}: missing defaults`);
      continue;
    }
    for (const field of fields) {
      if (["recurringDepositIntervalUnit", "pricingMode", "exitMode", "inventoryMode"].includes(field)) {
        if (batchDefault[field] !== backDefault[field]) {
          mismatches.push(`${profile}.${field}: batch=${batchDefault[field]} back=${backDefault[field]}`);
        }
        continue;
      }
      if (!sameNumber(batchDefault[field], backDefault[field])) {
        mismatches.push(`${profile}.${field}: batch=${batchDefault[field]} back=${backDefault[field]}`);
      }
    }
  }
  return mismatches;
}

function parseBatchExecutionPolicies(text, profiles) {
  const body = extractJavaMethodBody(text, /static ProfileExecutionPolicy defaults\s*\(/);
  return combineExecutionPolicies(
    profiles,
    parseConditionalProfileMode(
      body,
      "AutoParticipantProfileType",
      "ProfilePricingMode",
      profiles,
    ),
    parseSwitchProfileModes(body, "ProfileExitMode", profiles),
    parseConstantProfileMode(body, "ProfileInventoryMode"),
  );
}

function parseBackExecutionPolicies(text, profiles) {
  const pricingBody = extractJavaMethodBody(text, /static AutoParticipantProfilePricingMode pricingModeFor\s*\(/);
  const exitBody = extractJavaMethodBody(text, /static AutoParticipantProfileExitMode exitModeFor\s*\(/);
  const inventoryBody = extractJavaMethodBody(text, /static AutoParticipantProfileInventoryMode inventoryModeFor\s*\(/);
  return combineExecutionPolicies(
    profiles,
    parseConditionalProfileMode(
      pricingBody,
      "AutoParticipantProfileType",
      "AutoParticipantProfilePricingMode",
      profiles,
    ),
    parseSwitchProfileModes(exitBody, "AutoParticipantProfileExitMode", profiles),
    parseConstantProfileMode(inventoryBody, "AutoParticipantProfileInventoryMode"),
  );
}

function extractJavaMethodBody(text, signaturePattern) {
  const signature = signaturePattern.exec(text);
  if (!signature) {
    throw new Error(`Java method not found: ${signaturePattern}`);
  }
  const openBrace = text.indexOf("{", signature.index + signature[0].length);
  if (openBrace < 0) {
    throw new Error(`Java method body not found: ${signaturePattern}`);
  }
  let depth = 0;
  for (let index = openBrace; index < text.length; index++) {
    if (text[index] === "{") {
      depth++;
    } else if (text[index] === "}") {
      depth--;
      if (depth === 0) {
        return text.slice(openBrace + 1, index);
      }
    }
  }
  throw new Error(`Java method body is not balanced: ${signaturePattern}`);
}

function parseConstantProfileMode(body, modeEnumName) {
  const modeEnum = escapeRegExp(modeEnumName);
  const matches = [...body.matchAll(new RegExp(`${modeEnum}\\.([A-Z_]+)`, "g"))];
  const values = [...new Set(matches.map((match) => match[1]))];
  const match = values.length === 1 ? values[0] : null;
  if (!match) {
    throw new Error(`${modeEnumName} constant profile mapping not found`);
  }
  return {
    overrides: new Map(),
    defaultValue: match,
  };
}

function parseConditionalProfileMode(
  body,
  profileEnumName,
  modeEnumName,
  profiles,
) {
  const profileEnum = escapeRegExp(profileEnumName);
  const modeEnum = escapeRegExp(modeEnumName);
  const match = body.match(new RegExp(
    `profileType\\s*==\\s*${profileEnum}\\.([A-Z_]+)[\\s\\S]*?`
      + `\\?\\s*${modeEnum}\\.([A-Z_]+)\\s*`
      + `:\\s*${modeEnum}\\.([A-Z_]+)`,
  ));
  if (!match) {
    throw new Error(`${modeEnumName} conditional profile mapping not found`);
  }
  return {
    overrides: new Map([[match[1], match[2]]]),
    defaultValue: match[3],
    profiles,
  };
}

function parseSwitchProfileModes(body, modeEnumName, profiles) {
  const modeEnum = escapeRegExp(modeEnumName);
  const mappings = new Map();
  const casePattern = new RegExp(`case\\s+([A-Z_,\\s]+?)\\s*->\\s*${modeEnum}\\.([A-Z_]+)\\s*;`, "g");
  for (const match of body.matchAll(casePattern)) {
    for (const profile of match[1].split(",").map((value) => value.trim()).filter(Boolean)) {
      mappings.set(profile, match[2]);
    }
  }
  const defaultMatch = body.match(new RegExp(`default\\s*->\\s*${modeEnum}\\.([A-Z_]+)\\s*;`));
  if (!defaultMatch) {
    throw new Error(`${modeEnumName} default profile mapping not found`);
  }
  for (const profile of profiles) {
    if (!mappings.has(profile)) {
      mappings.set(profile, defaultMatch[1]);
    }
  }
  return mappings;
}

function combineExecutionPolicies(profiles, pricingModes, exitModes, inventoryModes) {
  return new Map(profiles.map((profile) => [profile, {
    pricingMode: pricingModes.overrides.get(profile) ?? pricingModes.defaultValue,
    exitMode: exitModes.get(profile),
    inventoryMode: inventoryModes.overrides.get(profile) ?? inventoryModes.defaultValue,
  }]));
}

function withExecutionPolicy(defaults, executionPolicy) {
  if (!executionPolicy) {
    throw new Error("explicit execution policy is missing");
  }
  return {
    ...defaults,
    decisionFrequencyMultiplier: defaults.orderMultiplier / defaults.orderTtlMultiplier,
    ordersPerDecisionMultiplier: defaults.orderMultiplier,
    ...executionPolicy,
  };
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function splitArguments(text) {
  const args = [];
  let current = "";
  let depth = 0;
  let quote = null;
  for (const char of text) {
    if (quote) {
      current += char;
      if (char === quote) {
        quote = null;
      }
      continue;
    }
    if (char === "\"" || char === "'") {
      quote = char;
      current += char;
      continue;
    }
    if (char === "(") {
      depth++;
      current += char;
      continue;
    }
    if (char === ")") {
      depth--;
      current += char;
      continue;
    }
    if (char === "," && depth === 0) {
      args.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  if (current.trim()) {
    args.push(current.trim());
  }
  return args;
}

function parseJavaValue(value, sourceText) {
  const trimmed = value.trim();
  if (trimmed === "BigDecimal.ZERO") {
    return 0;
  }
  if (trimmed === "DEFAULT_RECURRING_DEPOSIT_INTERVAL_DAYS") {
    const match = sourceText.match(/DEFAULT_RECURRING_DEPOSIT_INTERVAL_DAYS\s*=\s*(\d+)/);
    if (!match) {
      throw new Error("DEFAULT_RECURRING_DEPOSIT_INTERVAL_DAYS not found");
    }
    return Number(match[1]);
  }
  const bigDecimalMatch = trimmed.match(/new BigDecimal\("([0-9.]+)"\)/);
  if (bigDecimalMatch) {
    return Number(bigDecimalMatch[1]);
  }
  const stringNumberMatch = trimmed.match(/^"([0-9.]+)"$/);
  if (stringNumberMatch) {
    return Number(stringNumberMatch[1]);
  }
  return Number(trimmed);
}

function parseJavaUnitValue(value) {
  const trimmed = value.trim();
  const enumMatch = trimmed.match(/RecurringCashIntervalUnit\.([A-Z_]+)/);
  if (enumMatch) {
    return enumMatch[1];
  }
  const stringMatch = trimmed.match(/^"([A-Z_]+)"$/);
  return stringMatch ? stringMatch[1] : trimmed;
}

function sameNumber(left, right) {
  return Math.abs(left - right) < 0.0000001;
}

function parseDdlConstraintProfiles(text, constraintName) {
  const escapedConstraintName = constraintName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = text.match(new RegExp(`CONSTRAINT ${escapedConstraintName} CHECK \\(([\\s\\S]*?)\\n\\s*\\)`, "m"));
  if (!match) {
    throw new Error(`${constraintName} constraint not found`);
  }
  return [...match[1].matchAll(/WHEN '([A-Z_]+)' THEN 1/g)]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseMarkdownProfileTable(text) {
  const section = text.match(/## 자동 참여자 프로필([\s\S]*?)\n## /);
  if (!section) {
    throw new Error("auto participant profile section not found");
  }
  return [...section[1].matchAll(/\| `([A-Z_]+)` \|/g)].map((matchItem) => matchItem[1]);
}

function parseRuntimeTestProfiles(text, profiles) {
  const coversEveryProfile =
    /createDefault_registersExactlyOneV4BehaviorForEveryProfile/.test(text)
    && /containsOnlyKeys\(AutoParticipantProfileType\.values\(\)\)/.test(text)
    && /decide_everyProfileProducesReplayableDecisionAndComposedThoughtTrace/.test(text);
  return coversEveryProfile ? [...profiles] : [];
}

function profileBehaviorMarkerMismatches(text, profiles) {
  if (!profiles.length) {
    return ["V4 profile registry contract is missing"];
  }
  const requiredV4Contracts = [
    /createDefault_registersExactlyOneV4BehaviorForEveryProfile/,
    /containsOnlyKeys\(AutoParticipantProfileType\.values\(\)\)/,
    /decide_everyProfileProducesReplayableDecisionAndComposedThoughtTrace/,
    /hasSameSizeAs\(behavior\.moduleTypes\(\)\)/,
    /isEqualTo\(replay\)/,
  ];
  return requiredV4Contracts
    .filter((marker) => !marker.test(text))
    .map((marker) => `missing V4 contract ${marker}`);
}

function sameSet(left, right) {
  return diff(left, right).missing.length === 0 && diff(left, right).extra.length === 0;
}

function diff(left, right) {
  return {
    missing: left.filter((value) => !right.includes(value)),
    extra: right.filter((value) => !left.includes(value)),
  };
}

function formatDiff(detail) {
  const parts = [];
  if (detail.missing.length) {
    parts.push(`missing=${detail.missing.join(",")}`);
  }
  if (detail.extra.length) {
    parts.push(`extra=${detail.extra.join(",")}`);
  }
  return parts.length ? ` (${parts.join(" ")})` : "";
}
