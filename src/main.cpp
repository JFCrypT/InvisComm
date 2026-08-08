#include <Arduino.h>

#if defined(NODE_A)
constexpr const char* NODE_NAME = "ESP32 A";
#elif defined(NODE_B)
constexpr const char* NODE_NAME = "ESP32 B";
#else
constexpr const char* NODE_NAME = "ESP32 desconocido";
#endif

void setup()
{
    Serial.begin(115200);
    delay(1500);

    Serial.println();
    Serial.println("InvisComm ESP32");
    Serial.printf("%s iniciado correctamente\n", NODE_NAME);
}

void loop()
{
    Serial.printf(
        "%s funcionando - tiempo: %lu ms\n",
        NODE_NAME,
        static_cast<unsigned long>(millis())
    );

    delay(1000);
}