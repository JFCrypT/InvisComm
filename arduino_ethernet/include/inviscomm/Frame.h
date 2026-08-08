#pragma once
#include <Arduino.h>

namespace InvisFrame {
static const uint8_t SIZE = 12;
static const uint8_t MAGIC = 0x49; // 'I'
static const uint8_t VERSION = 1;
static const uint8_t NODE_A = 1;
static const uint8_t NODE_B = 2;

uint16_t crc16CcittFalse(const uint8_t* data, size_t len);
void encode(uint8_t sender,uint8_t flags,uint32_t position,uint16_t coordinate,uint8_t out[SIZE]);
bool decode(const uint8_t in[SIZE],uint8_t& sender,uint8_t& flags,uint32_t& position,uint16_t& coordinate);
}
