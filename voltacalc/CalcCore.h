//
//  CalcCore.h
//  The calculator's arithmetic, kept free of any UI so it can be tested on
//  its own. Multiplication and division bind tighter than addition and
//  subtraction: 2 + 3 x 4 = 14.
//

#ifndef VLT_CALC_CORE_H
#define VLT_CALC_CORE_H

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct {
    char   entry[24];      // digits being typed, e.g. "12.50"; empty when showing a result
    double value;          // what the display shows when entry is empty
    double low;  char lowOp;    // pending + or -
    double high; char highOp;   // pending x or /
    char   repeatOp; double repeatOperand;   // pressing = again repeats the last step
    bool   lastWasOp;      // an operator was the last key (so another one replaces it)
    bool   error;
} Calc;

static inline void calc_reset(Calc *c) { memset(c, 0, sizeof(*c)); }

static inline double calc_current(const Calc *c) { return c->entry[0] ? strtod(c->entry, NULL) : c->value; }

static inline double calc_apply(Calc *c, double a, char op, double b) {
    switch (op) {
        case '+': return a + b;
        case '-': return a - b;
        case '*': return a * b;
        case '/': if (b == 0) { c->error = true; return 0; } return a / b;
        default:  return b;
    }
}

static inline void calc_digit(Calc *c, char digit) {
    if (c->error) calc_reset(c);
    size_t len = strlen(c->entry), digits = 0;
    for (size_t i = 0; i < len; i++) if (c->entry[i] >= '0' && c->entry[i] <= '9') digits++;
    if (digits >= 9) return;                                   // nine digits, like a pocket calculator
    if (len == 1 && c->entry[0] == '0') len = 0;                 // no leading zeros
    if (len == 2 && c->entry[0] == '-' && c->entry[1] == '0') len = 1;
    c->entry[len] = digit;
    c->entry[len + 1] = '\0';
    c->lastWasOp = false;
}

static inline void calc_dot(Calc *c) {
    if (c->error) calc_reset(c);
    if (strchr(c->entry, '.')) return;
    if (!c->entry[0]) strcpy(c->entry, "0");
    if (strlen(c->entry) < sizeof(c->entry) - 2) strcat(c->entry, ".");
    c->lastWasOp = false;
}

static inline void calc_set_value(Calc *c, double v) {
    c->entry[0] = '\0';
    c->value = v;
}

static inline void calc_negate(Calc *c) {
    if (c->error) return;
    if (c->entry[0]) {
        if (c->entry[0] == '-') memmove(c->entry, c->entry + 1, strlen(c->entry));
        else if (strlen(c->entry) < sizeof(c->entry) - 2) { memmove(c->entry + 1, c->entry, strlen(c->entry) + 1); c->entry[0] = '-'; }
    } else {
        c->value = -c->value;
    }
}

// 50 + 10 % gives 55 (ten percent of fifty); a lone 50 % gives 0.5.
static inline void calc_percent(Calc *c) {
    if (c->error) return;
    double v = calc_current(c);
    double base = c->highOp ? 1 : (c->lowOp ? c->low : 1);
    calc_set_value(c, (c->lowOp && !c->highOp) ? base * v / 100.0 : v / 100.0);
    c->lastWasOp = false;
}

static inline void calc_operator(Calc *c, char op) {
    if (c->error) return;
    double v = calc_current(c);
    if (c->lastWasOp) {
        // Changing your mind: take back the operator that was just pressed.
        if (c->highOp) { v = c->high; c->highOp = 0; }
        else if (c->lowOp) { v = c->low; c->lowOp = 0; }
    }
    if (op == '*' || op == '/') {
        if (c->highOp) v = calc_apply(c, c->high, c->highOp, v);
        c->high = v;
        c->highOp = op;
    } else {
        if (c->highOp) { v = calc_apply(c, c->high, c->highOp, v); c->highOp = 0; }
        if (c->lowOp) v = calc_apply(c, c->low, c->lowOp, v);
        c->low = v;
        c->lowOp = op;
    }
    calc_set_value(c, v);
    c->lastWasOp = true;
    c->repeatOp = 0;
}

static inline void calc_equals(Calc *c) {
    if (c->error) return;
    double v = calc_current(c);
    if (!c->highOp && !c->lowOp) {
        if (c->repeatOp) v = calc_apply(c, v, c->repeatOp, c->repeatOperand);
    } else {
        // Remember the last step so that = = = keeps applying it.
        c->repeatOp = c->highOp ? c->highOp : c->lowOp;
        c->repeatOperand = v;
        if (c->highOp) { v = calc_apply(c, c->high, c->highOp, v); c->highOp = 0; }
        if (c->lowOp)  { v = calc_apply(c, c->low, c->lowOp, v);   c->lowOp = 0; }
    }
    calc_set_value(c, v);
    c->lastWasOp = false;
}

// Text for the display: what is being typed, or the value trimmed to nine
// significant digits (switching to exponent form when it will not fit).
static inline void calc_display(const Calc *c, char *out, size_t size) {
    if (c->error) { snprintf(out, size, "Error"); return; }
    if (c->entry[0]) { snprintf(out, size, "%s", c->entry); return; }
    double v = c->value;
    if (v == 0) { snprintf(out, size, "0"); return; }      // also turns -0 into 0
    if (!isfinite(v)) { snprintf(out, size, "Error"); return; }
    double magnitude = fabs(v);
    if (magnitude >= 1e9 || magnitude < 1e-8) {
        char buffer[40];
        snprintf(buffer, sizeof(buffer), "%.5e", v);          // d.ddddde+XX
        char *e = strchr(buffer, 'e');
        int exponent = e ? atoi(e + 1) : 0;
        if (e) *e = '\0';
        char *end = buffer + strlen(buffer) - 1;
        while (end > buffer && *end == '0') *end-- = '\0';
        if (*end == '.') *end = '\0';
        snprintf(out, size, "%se%d", buffer, exponent);
        return;
    }
    char buffer[40];
    snprintf(buffer, sizeof(buffer), "%.9g", v);
    if (strchr(buffer, 'e')) snprintf(buffer, sizeof(buffer), "%.8f", v);
    if (strchr(buffer, '.')) {
        char *end = buffer + strlen(buffer) - 1;
        while (end > buffer && *end == '0') *end-- = '\0';
        if (*end == '.') *end = '\0';
    }
    snprintf(out, size, "%s", buffer);
}

#endif
