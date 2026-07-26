const PLAID_LINK_SRC = "https://cdn.plaid.com/link/v2/stable/link-initialize.js";

let plaidScriptPromise = null;

const loadPlaidScript = () => {
  if (window.Plaid) {
    return Promise.resolve(window.Plaid);
  }

  if (!plaidScriptPromise) {
    plaidScriptPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = PLAID_LINK_SRC;
      script.async = true;
      script.onload = () => resolve(window.Plaid);
      script.onerror = () => reject(new Error("Unable to load Plaid Link."));
      document.head.appendChild(script);
    });
  }

  return plaidScriptPromise;
};

const PlaidLink = {
  mounted() {
    this.handleEvent("plaid:open", ({ link_token: linkToken }) => {
      loadPlaidScript()
        .then((Plaid) => {
          const handler = Plaid.create({
            token: linkToken,
            onSuccess: (publicToken, metadata) => {
              this.pushEvent("plaid-link-success", {
                public_token: publicToken,
                metadata
              });
            },
            onExit: (error, metadata) => {
              this.pushEvent("plaid-link-exit", { error, metadata });
            }
          });

          handler.open();
        })
        .catch(() => {
          this.pushEvent("plaid-link-exit", { error: { error_message: "load_failed" } });
        });
    });
  }
};

export default PlaidLink;
