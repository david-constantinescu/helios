// Helios — habitat sensor node for an Arduino Uno.
//
// Simulates the habitat's sensors and reads a PS2-style analog joystick (KY-023), then streams everything to the
// Raspberry Pi hub over USB serial (115200 baud, one line per message):
//
//   H,crew-sensors,<version>,<sensor keys>           hello, sent at boot and on "C,hello"
//   S,<seq>,t=22.41,rh=45.2,p=101.32,co2=612,...      one sensor frame per second (key=value, any order)
//   J,<L|R|U|D|P|H>                                   joystick: left/right/up/down, press, hold (long press)
//   A,<command>,ok|err                                reply to a command from the hub
//
// Commands from the hub:  C,hello   C,ping   C,scenario,<normal|co2|spike|leak|heat|noise>   C,rate,<ms>
//
// Wiring (joystick):  VRx → A0   VRy → A1   SW → D2   +5V → 5V   GND → GND
// Each read*() function below is where a real sensor goes later (DHT22/BME280, SCD41 CO2, a Geiger tube, …);
// the rest of the sketch and the hub stay the same.

const char VERSION[] = "1.0";
const uint8_t PIN_X = A0, PIN_Y = A1, PIN_SW = 2, PIN_SEED = A5, PIN_LED = LED_BUILTIN;

// ---- Joystick -----------------------------------------------------------------------------------------------
const int DEAD_LO = 250, DEAD_HI = 770;          // outside this band the stick counts as pushed
const unsigned long REPEAT_DELAY = 450, REPEAT_EVERY = 160, HOLD_MS = 700, DEBOUNCE_MS = 30;
char stickDir = 0;                                // direction currently held (0 = centred)
unsigned long stickSince = 0, stickLastFire = 0;
bool btnDown = false, btnHoldSent = false, btnRaw = false;
unsigned long btnChangedAt = 0, btnDownAt = 0;

// ---- Simulation ---------------------------------------------------------------------------------------------
enum Scenario { NORMAL, CO2_RISE, RAD_SPIKE, PRESSURE_LEAK, HEAT, NOISE_EVENT };
Scenario scenario = NORMAL;
unsigned long scenarioStart = 0;
unsigned long frameEvery = 1000, lastFrame = 0;
unsigned long seq = 0;
float co2 = 600, cabinTemp = 22.4, humidity = 44, pressure = 101.3, o2 = 20.9;

float noise1() { return (random(-1000, 1001) + random(-1000, 1001) + random(-1000, 1001)) / 3000.0; }   // ≈ N(0, 0.33)

// Crew "day" is 16 h awake in a 24 h cycle; compressed so a full day passes in 24 minutes for demos.
float dayPhase() { return fmod(millis() / 60000.0, 24.0) / 24.0; }
bool lightsOn() { float h = dayPhase() * 24; return h >= 6 && h < 22; }
float scenarioMinutes() { return (millis() - scenarioStart) / 60000.0; }

float readCabinTemp() {
  float target = 22.0 + 0.6 * sin(dayPhase() * 2 * PI) + (scenario == HEAT ? min(6.0, scenarioMinutes() * 1.5) : 0);
  cabinTemp += (target - cabinTemp) * 0.05 + noise1() * 0.03;
  return cabinTemp;
}
float readHumidity() {
  float target = 42 + 6 * (lightsOn() ? 1 : 0.4);
  humidity += (target - humidity) * 0.03 + noise1() * 0.15;
  return constrain(humidity, 5, 95);
}
float readPressure() {
  float target = scenario == PRESSURE_LEAK ? 101.3 - min(12.0, scenarioMinutes() * 0.8) : 101.3;
  pressure += (target - pressure) * 0.08 + noise1() * 0.02;
  return pressure;
}
float readCO2() {
  // Crew breathing adds CO2; the scrubber removes it. In the CO2 scenario the scrubber is degraded.
  float add = lightsOn() ? 2.2 : 1.2;
  float scrub = scenario == CO2_RISE ? 0.0006 : 0.0032;
  co2 += add - (co2 - 420) * scrub + noise1() * 6;
  return constrain(co2, 380, 8000);
}
float readO2() {
  float target = 20.9 - (scenario == PRESSURE_LEAK ? 0.02 * scenarioMinutes() : 0);
  o2 += (target - o2) * 0.05 + noise1() * 0.02;
  return o2;
}
float readNoise() {
  float base = lightsOn() ? 56 : 48;
  if (scenario == NOISE_EVENT) base += 22;
  return base + noise1() * 3;
}
float readLux() { return lightsOn() ? 320 + noise1() * 15 : 2 + abs(noise1()); }
float readDoseRate() {
  // Background ~0.10 µSv/h; the spike ramps to ×80 over 2 minutes and decays over ~10 minutes.
  float r = 0.10 + noise1() * 0.012;
  if (scenario == RAD_SPIKE) {
    float m = scenarioMinutes();
    r += m < 2 ? 8.0 * m / 2 : 8.0 * exp(-(m - 2) / 4.0);
    if (m > 30) scenario = NORMAL;
  }
  return max(0.01, r);
}

void sendHello() {
  Serial.print(F("H,crew-sensors,")); Serial.print(VERSION);
  Serial.println(F(",t,rh,p,co2,o2,db,lux,rad,cpm,scn"));
}

void sendFrame() {
  float rad = readDoseRate();
  Serial.print(F("S,")); Serial.print(seq++);
  Serial.print(F(",t="));   Serial.print(readCabinTemp(), 2);
  Serial.print(F(",rh="));  Serial.print(readHumidity(), 1);
  Serial.print(F(",p="));   Serial.print(readPressure(), 2);
  Serial.print(F(",co2=")); Serial.print(readCO2(), 0);
  Serial.print(F(",o2="));  Serial.print(readO2(), 2);
  Serial.print(F(",db="));  Serial.print(readNoise(), 1);
  Serial.print(F(",lux=")); Serial.print(readLux(), 0);
  Serial.print(F(",rad=")); Serial.print(rad, 3);
  Serial.print(F(",cpm=")); Serial.print(max(0.0, rad * 180 + noise1() * 4), 0);
  Serial.print(F(",scn=")); Serial.println((int)scenario);
}

// ---- Joystick ------------------------------------------------------------------------------------------------
void emit(char c) { Serial.print(F("J,")); Serial.println(c); digitalWrite(PIN_LED, HIGH); }

void pollStick(unsigned long now) {
  int x = analogRead(PIN_X), y = analogRead(PIN_Y);
  char d = 0;
  if (x < DEAD_LO) d = 'L'; else if (x > DEAD_HI) d = 'R';
  else if (y < DEAD_LO) d = 'U'; else if (y > DEAD_HI) d = 'D';
  if (d != stickDir) {
    stickDir = d; stickSince = now; stickLastFire = now;
    if (d) emit(d);
  } else if (d && now - stickSince > REPEAT_DELAY && now - stickLastFire > REPEAT_EVERY) {
    stickLastFire = now; emit(d);            // auto-repeat while held (scrolling long lists)
  }
}

void pollButton(unsigned long now) {
  bool raw = digitalRead(PIN_SW) == LOW;    // INPUT_PULLUP: pressed = LOW
  if (raw != btnRaw) { btnRaw = raw; btnChangedAt = now; }
  if (now - btnChangedAt < DEBOUNCE_MS || raw == btnDown) {
    if (btnDown && !btnHoldSent && now - btnDownAt > HOLD_MS) { btnHoldSent = true; emit('H'); }
    return;
  }
  btnDown = raw;
  if (btnDown) { btnDownAt = now; btnHoldSent = false; }
  else if (!btnHoldSent) emit('P');
}

// ---- Commands from the hub -----------------------------------------------------------------------------------
char cmd[48];
uint8_t cmdLen = 0;

void handleCommand(char *line) {
  if (strncmp(line, "C,", 2) != 0) return;
  char *c = line + 2;
  if (strcmp(c, "hello") == 0) { sendHello(); return; }
  if (strcmp(c, "ping") == 0) { Serial.println(F("A,ping,ok")); return; }
  if (strncmp(c, "rate,", 5) == 0) {
    long ms = atol(c + 5);
    if (ms >= 200 && ms <= 60000) { frameEvery = ms; Serial.println(F("A,rate,ok")); } else Serial.println(F("A,rate,err"));
    return;
  }
  if (strncmp(c, "scenario,", 9) == 0) {
    const char *s = c + 9;
    Scenario next;
    if (strcmp(s, "normal") == 0) next = NORMAL;
    else if (strcmp(s, "co2") == 0) next = CO2_RISE;
    else if (strcmp(s, "spike") == 0) next = RAD_SPIKE;
    else if (strcmp(s, "leak") == 0) next = PRESSURE_LEAK;
    else if (strcmp(s, "heat") == 0) next = HEAT;
    else if (strcmp(s, "noise") == 0) next = NOISE_EVENT;
    else { Serial.println(F("A,scenario,err")); return; }
    scenario = next; scenarioStart = millis();
    Serial.println(F("A,scenario,ok"));
    return;
  }
  Serial.println(F("A,unknown,err"));
}

void pollSerial() {
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\r') continue;
    if (ch == '\n') { cmd[cmdLen] = 0; handleCommand(cmd); cmdLen = 0; }
    else if (cmdLen < sizeof(cmd) - 1) cmd[cmdLen++] = ch;
    else cmdLen = 0;                          // overlong line: drop it
  }
}

void setup() {
  pinMode(PIN_SW, INPUT_PULLUP);
  pinMode(PIN_LED, OUTPUT);
  randomSeed(analogRead(PIN_SEED) ^ (analogRead(PIN_X) << 3));
  Serial.begin(115200);
  delay(50);
  sendHello();
}

void loop() {
  unsigned long now = millis();
  pollSerial();
  pollStick(now);
  pollButton(now);
  if (now - lastFrame >= frameEvery) { lastFrame = now; sendFrame(); }
  if (now - stickLastFire > 60 && now - btnChangedAt > 60) digitalWrite(PIN_LED, LOW);
  delay(5);
}
