import React from "react";
import Image from "next/image";
import Link from "next/link";

import type { CurrentUserProfile } from "./lib/current-user";
import { getCurrentUser } from "./lib/current-user";

const featureHighlights = [
  {
    icon: "/moneytree-insights.svg",
    title: "Unified insights",
    description:
      "Connect accounts, track budgets, and watch MoneyTree surface the patterns that matter most to your goals."
  },
  {
    icon: "/moneytree-automation.svg",
    title: "Automated planning",
    description:
      "Scenario planning and automated savings rules keep every branch of your financial life healthy without manual spreadsheets."
  },
  {
    icon: "/moneytree-security.svg",
    title: "Bank-grade security",
    description:
      "End-to-end encryption, role-based access, and privacy-first analytics protect every data leaf you store with us."
  }
];

const quickActions = [
  {
    href: "/app/dashboard",
    title: "Open dashboard",
    description: "Review cash flow, runway, and portfolio trends at a glance.",
  },
  {
    href: "/app/transfers",
    title: "Manage transfers",
    description: "Schedule or approve movements between your connected accounts.",
  },
  {
    href: "/control-panel",
    title: "Update settings",
    description: "Adjust roles, security policies, and workspace preferences.",
  },
  {
    href: "/control-panel",
    title: "Visit control panel",
    description: "Access owner-level tooling and advanced automations.",
  },
];

type HomeContentProps = {
  currentUser: CurrentUserProfile | null;
};

function HomeContent({ currentUser }: HomeContentProps) {
  const isGuest = !currentUser;
  const greetingName =
    currentUser && (currentUser.name?.trim() || currentUser.email);

  return (
    <div className="bg-background text-foreground min-h-screen">
      <header className="mx-auto flex w-full max-w-6xl items-center justify-between gap-4 px-6 py-8">
        <div className="flex items-center gap-3">
          <Image
            src="/moneytree-logo.svg"
            alt="MoneyTree logo"
            width={160}
            height={40}
            priority
          />
          <span className="hidden text-lg font-semibold tracking-tight sm:inline">MoneyTree</span>
        </div>
        <div className="flex items-center gap-3 text-sm font-medium">
          {isGuest && (
            <a
              className="rounded-full border border-primary/30 px-5 py-2 text-primary hover:border-primary hover:text-primary transition"
              href="/login"
            >
              Log in
            </a>
          )}
          <a
            className="rounded-full bg-primary px-5 py-2 text-primary-foreground shadow hover:bg-secondary transition"
            href="#get-started"
          >
            Start free trial
          </a>
          <a
            className="rounded-full border border-primary/30 px-5 py-2 text-primary hover:border-primary hover:text-primary transition"
            href="#learn-more"
          >
            Learn more
          </a>
        </div>
      </header>

      <main className="mx-auto flex w-full max-w-6xl flex-col gap-16 px-6 pb-24">
        <section className="grid gap-16 lg:grid-cols-2 lg:items-center">
          <div className="flex flex-col gap-6">
            <span className="inline-flex w-fit items-center rounded-full bg-primary/10 px-4 py-2 text-sm font-medium text-primary">
              Smart finance orchestration
            </span>
            <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
              Grow healthy finances with confidence.
            </h1>
            <p className="text-lg text-slate-300">
              MoneyTree unifies budgets, investments, and recurring cash flow into a personalized growth plan. Visual coaching and actionable automation make it effortless to cultivate long-term wealth.
            </p>
            <div className="flex flex-col gap-4 sm:flex-row" id="get-started">
              <a
                className="inline-flex items-center justify-center rounded-full bg-accent px-6 py-3 text-base font-semibold text-accent-foreground shadow hover:bg-primary transition"
                href="/signup"
              >
                Create my plan
              </a>
              <a
                className="inline-flex items-center justify-center rounded-full border border-accent/40 px-6 py-3 text-base font-semibold text-accent hover:border-accent hover:text-accent transition"
                href="#learn-more"
              >
                See how it works
              </a>
            </div>
            <div className="grid gap-6 rounded-2xl bg-neutral/20 p-6 shadow" id="learn-more">
              {featureHighlights.map((feature) => (
                <div key={feature.title} className="flex items-start gap-4">
                  <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-background/70 shadow-inner">
                    <Image src={feature.icon} alt="" width={32} height={32} aria-hidden />
                  </div>
                  <div className="space-y-1">
                    <h2 className="text-lg font-semibold text-foreground">{feature.title}</h2>
                    <p className="text-sm text-slate-300">{feature.description}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div className="relative flex items-center justify-center">
            <div className="absolute inset-10 rounded-[48px] bg-primary/20 blur-3xl" aria-hidden />
            <div className="relative w-full max-w-xl overflow-hidden rounded-[40px] border border-primary/30 bg-neutral/40 p-4 shadow-lg">
              <div className="overflow-hidden rounded-[32px] bg-black/40">
                <Image
                  src="/moneytree-hero.svg"
                  alt="MoneyTree dashboard illustration"
                  width={720}
                  height={540}
                  sizes="(min-width: 1024px) 560px, 100vw"
                  className="h-auto w-full"
                  priority
                />
              </div>
            </div>
          </div>
        </section>
        {currentUser && (
          <section className="grid gap-8 rounded-3xl border border-primary/30 bg-neutral/40 p-8 shadow" aria-labelledby="quick-actions">
            <div className="space-y-2">
              <span className="inline-flex w-fit items-center rounded-full bg-primary/10 px-4 py-1 text-xs font-semibold uppercase tracking-wide text-primary">
                Personalized overview
              </span>
              <h2 id="quick-actions" className="text-2xl font-semibold text-foreground">
                Welcome back, {greetingName}!
              </h2>
              <p className="text-sm text-slate-300">
                Jump right into the areas of MoneyTree you use most often. Each action opens in a new tab so you never lose your place.
              </p>
            </div>
            <div className="grid gap-4 md:grid-cols-2">
              {quickActions.map((action) => (
                <Link
                  key={`${action.href}-${action.title}`}
                  className="group flex flex-col justify-between rounded-2xl border border-primary/20 bg-background/40 p-5 transition hover:border-primary hover:bg-background/60"
                  href={action.href}
                >
                  <div className="space-y-1">
                    <p className="text-sm font-semibold text-foreground group-hover:text-primary transition">
                      {action.title}
                    </p>
                    <p className="text-sm text-slate-300">{action.description}</p>
                  </div>
                  <span className="mt-4 inline-flex items-center text-sm font-medium text-primary group-hover:translate-x-1 transition">
                    Go now →
                  </span>
                </Link>
              ))}
            </div>
          </section>
        )}
      </main>

      <footer className="border-t border-primary/20 bg-neutral/40">
        <div className="mx-auto flex w-full max-w-6xl flex-col items-center gap-2 px-6 py-8 text-center text-sm text-slate-400 sm:flex-row sm:justify-between">
          <p>&copy; {new Date().getFullYear()} MoneyTree. Helping teams cultivate lasting financial clarity.</p>
          <div className="flex gap-4">
            <a className="hover:text-primary transition" href="/privacy">
              Privacy
            </a>
            <a className="hover:text-primary transition" href="/security">
              Security
            </a>
            <a className="hover:text-primary transition" href="/support">
              Support
            </a>
          </div>
        </div>
      </footer>
    </div>
  );
}

type CurrentUserFetcher = () => Promise<CurrentUserProfile | null>;

export async function renderHomePage(
  fetchCurrentUser: CurrentUserFetcher = getCurrentUser,
) {
  const currentUser = await fetchCurrentUser();
  return <HomeContent currentUser={currentUser} />;
}

export default async function Home() {
  return renderHomePage();
}
