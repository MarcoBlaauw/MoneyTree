import { notFound } from "next/navigation";

import { getMortgageById } from "../../lib/mortgages";
import { MortgageDetailClient } from "./mortgage-detail-client";

export default async function MortgageDetailPage({
  params,
}: {
  params: Promise<{ mortgageId: string }>;
}) {
  const { mortgageId } = await params;
  const mortgage = await getMortgageById(mortgageId);

  if (!mortgage) {
    notFound();
  }

  return <MortgageDetailClient mortgage={mortgage} />;
}
