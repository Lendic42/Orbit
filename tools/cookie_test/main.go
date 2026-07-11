// cookie_test — standalone harness for the non-anonymous (cookie) cred path.
// Runs the EXACT same Go code the iOS extension would, from a Mac, so we can
// verify the ildarmaga remixsid→TURN recipe works for US before building any
// iOS UI.
//
// Usage:
//
//	go build -o /tmp/cookie-test ./tools/cookie_test
//	/tmp/cookie-test \
//	    --vk-link "https://vk.ru/call/join/<linkID>" \
//	    --cookie  "remixsid=1_th77...."        # value-only also accepted
//
// The cookie is a burner VK account's logged-in session cookie (remixsid).
// SUCCESS => the recipe mints TURN creds; we can then build the iOS side.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
)

func main() {
	link := flag.String("vk-link", "", "VK call link, e.g. https://vk.ru/call/join/<linkID>")
	cookie := flag.String("cookie", "", "remixsid cookie ('remixsid=…' or just the value)")
	flag.Parse()

	os.Setenv("VK_COOKIE_DEBUG", "1") // dump each step's raw response

	if *link == "" || *cookie == "" {
		log.Fatal("both --vk-link and --cookie are required")
	}

	id := *link
	if i := strings.LastIndex(id, "join/"); i >= 0 {
		id = id[i+len("join/"):]
	}
	id = strings.TrimRight(id, "/")
	if i := strings.IndexAny(id, "?#"); i > 0 {
		id = id[:i]
	}

	ch := strings.TrimSpace(*cookie)
	if !strings.Contains(ch, "=") {
		ch = "remixsid=" + ch // accept value-only
	}

	log.Printf("cookie path: link=%s cookie=%s…", id, trunc(ch, 24))
	creds, err := proxy.GetVKCredsViaCookies(id, ch)
	if err != nil {
		log.Fatalf("RESULT=FAILED — %v", err)
	}
	fmt.Printf("\nRESULT=SUCCESS\n  username  = %s\n  password  = %s\n  addresses = %v\n",
		creds.Username, mask(creds.Password), creds.Addresses)
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func mask(s string) string {
	if len(s) < 8 {
		return "***"
	}
	return s[:3] + "..." + s[len(s)-3:]
}
