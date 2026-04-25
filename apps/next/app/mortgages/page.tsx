import { MortgageOverviewClient } from "./mortgage-overview-client";
import { getMortgages } from "../lib/mortgages";

export default async function MortgageOverviewPage() {
  const mortgages = await getMortgages();

  return <MortgageOverviewClient initialMortgages={mortgages} />;
}
