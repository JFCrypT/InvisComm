#pragma once
#include <Arduino.h>

namespace InvisCommConfig {

static const uint32_t SHARED_KEY = 202603UL;
static const uint16_t TX_INTERVAL_MS = 300;
static const uint16_t START_DELAY_MS = 3000;
static const uint16_t UDP_PORT_ALICE = 42001;
static const uint16_t UDP_PORT_BOB = 42002;
static const uint8_t ETHERNET_CS_PIN = 10;
static const uint8_t SD_CS_PIN = 4;

static const char ALPHABET[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789"
    " "
    ".,;:!?()-_@*+=/";
static const uint8_t ALPHABET_LEN = sizeof(ALPHABET) - 1;

static const char MESSAGE_ALICE[] = "Attack from the northern front";
static const char MESSAGE_BOB[] = "Received. The attack will begin at 12:00";

}  // namespace InvisCommConfig
