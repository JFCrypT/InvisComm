#include "inviscomm/Sha256Lite.h"

namespace {
const uint32_t K[64] PROGMEM = {
  0x428a2f98UL,0x71374491UL,0xb5c0fbcfUL,0xe9b5dba5UL,0x3956c25bUL,0x59f111f1UL,0x923f82a4UL,0xab1c5ed5UL,
  0xd807aa98UL,0x12835b01UL,0x243185beUL,0x550c7dc3UL,0x72be5d74UL,0x80deb1feUL,0x9bdc06a7UL,0xc19bf174UL,
  0xe49b69c1UL,0xefbe4786UL,0x0fc19dc6UL,0x240ca1ccUL,0x2de92c6fUL,0x4a7484aaUL,0x5cb0a9dcUL,0x76f988daUL,
  0x983e5152UL,0xa831c66dUL,0xb00327c8UL,0xbf597fc7UL,0xc6e00bf3UL,0xd5a79147UL,0x06ca6351UL,0x14292967UL,
  0x27b70a85UL,0x2e1b2138UL,0x4d2c6dfcUL,0x53380d13UL,0x650a7354UL,0x766a0abbUL,0x81c2c92eUL,0x92722c85UL,
  0xa2bfe8a1UL,0xa81a664bUL,0xc24b8b70UL,0xc76c51a3UL,0xd192e819UL,0xd6990624UL,0xf40e3585UL,0x106aa070UL,
  0x19a4c116UL,0x1e376c08UL,0x2748774cUL,0x34b0bcb5UL,0x391c0cb3UL,0x4ed8aa4aUL,0x5b9cca4fUL,0x682e6ff3UL,
  0x748f82eeUL,0x78a5636fUL,0x84c87814UL,0x8cc70208UL,0x90befffaUL,0xa4506cebUL,0xbef9a3f7UL,0xc67178f2UL
};

inline uint32_t rotr(uint32_t x, uint8_t n) { return (x >> n) | (x << (32 - n)); }
inline uint32_t ch(uint32_t x,uint32_t y,uint32_t z){ return (x & y) ^ (~x & z); }
inline uint32_t maj(uint32_t x,uint32_t y,uint32_t z){ return (x & y) ^ (x & z) ^ (y & z); }
inline uint32_t ep0(uint32_t x){ return rotr(x,2) ^ rotr(x,13) ^ rotr(x,22); }
inline uint32_t ep1(uint32_t x){ return rotr(x,6) ^ rotr(x,11) ^ rotr(x,25); }
inline uint32_t sig0(uint32_t x){ return rotr(x,7) ^ rotr(x,18) ^ (x >> 3); }
inline uint32_t sig1(uint32_t x){ return rotr(x,17) ^ rotr(x,19) ^ (x >> 10); }
}

Sha256Lite::Sha256Lite(){ reset(); }
void Sha256Lite::reset(){
    state_[0]=0x6a09e667UL; state_[1]=0xbb67ae85UL; state_[2]=0x3c6ef372UL; state_[3]=0xa54ff53aUL;
    state_[4]=0x510e527fUL; state_[5]=0x9b05688cUL; state_[6]=0x1f83d9abUL; state_[7]=0x5be0cd19UL;
    bitLen_=0; bufferLen_=0;
}
void Sha256Lite::transform(const uint8_t block[64]){
    uint32_t w[64];
    for(uint8_t i=0;i<16;i++){
        const uint8_t j=i*4;
        w[i]=((uint32_t)block[j]<<24)|((uint32_t)block[j+1]<<16)|((uint32_t)block[j+2]<<8)|block[j+3];
    }
    for(uint8_t i=16;i<64;i++) w[i]=sig1(w[i-2])+w[i-7]+sig0(w[i-15])+w[i-16];
    uint32_t a=state_[0],b=state_[1],c=state_[2],d=state_[3],e=state_[4],f=state_[5],g=state_[6],h=state_[7];
    for(uint8_t i=0;i<64;i++){
        uint32_t t1=h+ep1(e)+ch(e,f,g)+pgm_read_dword(&K[i])+w[i];
        uint32_t t2=ep0(a)+maj(a,b,c);
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    state_[0]+=a; state_[1]+=b; state_[2]+=c; state_[3]+=d;
    state_[4]+=e; state_[5]+=f; state_[6]+=g; state_[7]+=h;
}
void Sha256Lite::update(const uint8_t* data,size_t len){
    for(size_t i=0;i<len;i++){
        buffer_[bufferLen_++]=data[i];
        if(bufferLen_==64){ transform(buffer_); bitLen_+=512; bufferLen_=0; }
    }
}
void Sha256Lite::final(uint8_t out[32]){
    uint64_t totalBits=bitLen_+((uint64_t)bufferLen_*8ULL);
    buffer_[bufferLen_++]=0x80;
    if(bufferLen_>56){ while(bufferLen_<64) buffer_[bufferLen_++]=0; transform(buffer_); bufferLen_=0; }
    while(bufferLen_<56) buffer_[bufferLen_++]=0;
    for(int8_t i=7;i>=0;i--) buffer_[bufferLen_++]=(uint8_t)(totalBits>>(i*8));
    transform(buffer_);
    for(uint8_t i=0;i<8;i++){
        out[i*4]=(uint8_t)(state_[i]>>24); out[i*4+1]=(uint8_t)(state_[i]>>16);
        out[i*4+2]=(uint8_t)(state_[i]>>8); out[i*4+3]=(uint8_t)state_[i];
    }
    reset();
}
void Sha256Lite::digest(const uint8_t* data,size_t len,uint8_t out[32]){ Sha256Lite h; h.update(data,len); h.final(out); }
