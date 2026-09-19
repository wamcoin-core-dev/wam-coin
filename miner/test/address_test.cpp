// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  address_test.cpp -- does the miner pay the address it was given?
// ===========================================================================
//
//      g++ -std=c++17 -I../src -o address_test address_test.cpp && ./address_test
//
//  Every other mistake in solo mining announces itself. A wrong output script
//  does not: the block is valid, the chain accepts it, and fifty coins are
//  paid to nothing, with no error at any point. The only symptom is a balance
//  that never arrives.
//
//  So the vectors below are not invented. Each pair was read off a real WAM
//  mainnet coinbase with `wam-cli getblock <hash> 2`, which means consensus
//  itself has already agreed that the script pays that address.
// ===========================================================================

#include <cstdio>
#include <string>

#include "address.h"

using namespace wam;

static int failures = 0;
static int checks   = 0;

static std::string Hex(const Bytes& b)
{
    static const char* d = "0123456789abcdef";
    std::string s;
    for (uint8_t c : b) { s += d[c >> 4]; s += d[c & 15]; }
    return s;
}

static void Pays(const char* address, const char* wantHex,
                 const char* network = "mainnet")
{
    checks++;
    try {
        const Bytes got = AddressToScript(address, NetParamsFor(network));
        if (Hex(got) == wantHex) {
            std::printf("  \033[32mok\033[0m    %s\n", address);
        } else {
            failures++;
            std::printf("  \033[31mFAIL\033[0m  %s\n        want %s\n        got  %s\n",
                        address, wantHex, Hex(got).c_str());
        }
    } catch (const std::exception& e) {
        failures++;
        std::printf("  \033[31mFAIL\033[0m  %s threw: %s\n", address, e.what());
    }
}

static void Refuses(const char* address, const char* why,
                    const char* network = "mainnet")
{
    checks++;
    try {
        AddressToScript(address, NetParamsFor(network));
        failures++;
        std::printf("  \033[31mFAIL\033[0m  accepted %s -- %s\n", address, why);
    } catch (const std::exception&) {
        std::printf("  \033[32mok\033[0m    refused: %s\n", why);
    }
}

int main()
{
    std::printf("\n\033[1mthe script pays the address it was given\033[0m\n");

    // ---- read off real mainnet coinbases, blocks 3338-3340 ----------------
    // The treasury, which consensus rule WAM-1 checks in every single block.
    Pays("WdMMqW1DcgWZ6HtyJuEMdce6QkKg4raGmE",
         "76a914a101cf17c209638136abe19e14dc4e1c9987370f88ac");

    // This pool's own payout address, and another miner's.
    Pays("wam1qrulaxxlqf65madsmhqrevf467r6qmgdrxhf9yw",
         "00141f3fd31be04ea9beb61bb8079626baf0f40da1a3");
    Pays("wam1q5lsgy00xkq2axdy6w985htrlxlpxcaw9kgnm8c",
         "0014a7e0823de6b015d3349a714f4bac7f37c26c75c5");

    std::printf("\n\033[1mand refuses what it must not pay\033[0m\n");

    // A single wrong character. This is exactly what the checksum is for, and
    // it is the difference between a miner being told and a miner being paid
    // into nowhere.
    Refuses("wam1qrulaxxlqf65madsmhqrevf467r6qmgdrxhf9yx",
            "one character changed in a bech32 address");
    Refuses("WdMMqW1DcgWZ6HtyJuEMdce6QkKg4raGmF",
            "one character changed in a base58 address");

    // Somebody else's chain. The routine mistake, and it deserves to be named
    // rather than reported as "invalid base58 character".
    Refuses("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            "a Bitcoin mainnet address");
    Refuses("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
            "a Bitcoin base58 address (version byte 0)");

    // Right coin, wrong network: a testnet address on a mainnet miner.
    Refuses("twam1qrulaxxlqf65madsmhqrevf467r6qmgdrxhnxymw",
            "a WAM testnet address given to a mainnet miner");

    Refuses("", "an empty address");
    Refuses("wam1", "a prefix with no payload");

    std::printf("\n  %d checks, %d failure(s)\n\n", checks, failures);
    return failures ? 1 : 0;
}
