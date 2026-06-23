/*
 * Standalone GPIO stepper probe for Thingino motor bring-up.
 *
 * Build this manually with a camera toolchain and upload the resulting binary
 * when testing unknown PTZ wiring. It is intentionally not installed into
 * production images.
 */

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define GPIO_BASE "/sys/class/gpio"
#define GPIO_CLAIM_PATH "/proc/gpio_claim/gpio"
#define MOTORS_CONFIG "/etc/motors.json"
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))

enum drive_mode {
	DRIVE_WAVE,
	DRIVE_FULL,
	DRIVE_HALF,
};

struct candidate {
	const char *label;
	const char *pins;
};

static const char *wave_sequence[] = {"1000", "0100", "0010", "0001"};
static const char *full_sequence[] = {"1100", "0110", "0011", "1001"};
static const char *half_sequence[] = {"1000", "1100", "0100", "0110",
	"0010", "0011", "0001", "1001"};

static const struct candidate known_candidates[] = {
	{"repo common: d1/q5/q7 pan", "49 63 62 61"},
	{"repo common: d1/q5/q7 tilt", "52 53 64 59"},
	{"repo common: jooan pan", "53 52 54 51"},
	{"repo common: jooan tilt", "51 54 52 53"},
	{"repo common: laview/g6 pan", "64 53 52 54"},
	{"repo common: laview/g6 tilt", "51 63 62 61"},
	{"repo common: y4/cp80x0 pan", "61 62 63 49"},
	{"repo common: y4/cp80x0 tilt", "59 52 53 64"},
	{"repo common: galayou g2 pan", "54 52 53 64"},
	{"repo common: galayou g2 tilt", "61 62 63 51"},
	{"repo common: wuuk pan", "61 62 63 51"},
	{"repo common: wuuk tilt", "54 52 53 64"},
	{"repo common: w7/y4-t31 pan", "49 61 62 63"},
	{"repo common: w7/y4-t31 tilt", "52 59 64 53"},
	{"repo common: aosu/dekco pan", "63 62 61 51"},
	{"repo common: aosu/dekco tilt", "54 52 53 41"},
	{"repo common: vanhua pan", "63 62 61 60"},
	{"repo common: vanhua tilt", "59 52 53 49"},
	{"repo common: sonoff pt2 pan", "58 53 52 54"},
	{"repo common: sonoff pt2 tilt", "63 62 61 51"},
	{"repo common: zte tilt", "54 53 52 59"},
	{"repo common: wyze t31 pan", "52 53 57 51"},
	{"repo common: wyze t31 tilt", "63 62 61 59"},
	{"repo common: feisda pan", "59 57 64 62"},
	{"repo common: feisda tilt", "58 49 63 61"},
	{"repo common: longplus pan", "53 62 61 60"},
	{"repo common: longplus tilt", "58 57 50 49"},
	{"repo common: pesita pan", "60 61 62 53"},
	{"repo common: campan pan", "54 51 49 57"},
	{"repo common: campan tilt", "63 62 61 60"},
	{"repo common: lower-bank pan", "7 6 8 10"},
	{"repo common: lower-bank tilt", "9 11 14 16"},
	{"repo common: jooan switch17 pan", "14 54 52 53"},
	{"repo common: jooan switch17 tilt", "53 52 54 14"},
	{"repo common: high-bank pan", "77 76 75 78"},
	{"repo common: high-bank alternate", "81 82 51 53"},
	{"cinnado b6 mould 804 shared phases", "51 54 57 38"},
};

static int current_pins[4] = {-1, -1, -1, -1};
static int current_pins_valid;
static int exported_pins[16];
static size_t exported_pins_count;
static int enable_gpio = -1;
static int enable_value = 1;
static int enable_exported;
static int pan_enable_gpio = -1;
static int tilt_enable_gpio = -1;
static int pan_enable_exported;
static int tilt_enable_exported;
static char axis_arg[16];
static int invert_gpio;
static int use_gpio_helper = 1;

static int steps = 64;
static int delay_us = 3000;
static enum drive_mode drive = DRIVE_WAVE;
static int reverse_sequence;
static int permute_pins;
static int pause_between;
static int scan_known;
static int pulse_mode;
static int quad_mode;
static int pair_mode;
static int keep_motor_stack;
static int allow_sdio_pins;
static int max_span;
static int max_tests;
static int tests_run;
static int tests_seen;
static int skip_tests;
static char pins_arg[128];
static char quad_pins_arg[1024];
static char quad_range_arg[64];
static char pair_pins_arg[1024];
static char pair_range_arg[64];
static char candidate_file_arg[256];
static char pulse_pins_arg[512];
static char pulse_range_arg[64];
static char exclude_arg[512];
static char from_config[16];
static int pulse_ms = 300;

static void usage(FILE *stream)
{
	fprintf(stream,
		"Usage:\n"
		"  motor-gpio-scan --pins \"p1 p2 p3 p4\" [options]\n"
		"  motor-gpio-scan --from-config pan|tilt [options]\n"
		"  motor-gpio-scan --scan-known [options]\n"
		"  motor-gpio-scan --quad-range A-B [options]\n"
		"  motor-gpio-scan --quad-pins \"p1 p2 ...\" [options]\n"
		"  motor-gpio-scan --candidate-file PATH [options]\n"
		"  motor-gpio-scan --pair-range A-B [options]\n"
		"  motor-gpio-scan --pair-pins \"p1 p2 ...\" [options]\n"
		"  motor-gpio-scan --pulse-range A-B [options]\n"
		"  motor-gpio-scan --pulse-pins \"p1 p2 ...\" [options]\n"
		"\n"
		"Options:\n"
		"  --steps N              Phase advances per test (default: 64)\n"
		"  --delay-us N           Delay between phases in microseconds (default: 3000)\n"
		"  --pulse-ms N           Single-pin pulse length in milliseconds (default: 300)\n"
		"  --drive wave|full|half Coil drive sequence (default: wave)\n"
		"  --reverse              Run the sequence in reverse\n"
		"  --invert               Treat GPIO outputs as active-low\n"
		"  --permute              Try all 24 phase orders for the supplied pins\n"
		"  --pause                Wait for Enter between candidates\n"
		"  --exclude \"p1 p2 ...\" Skip pins during generated scans\n"
		"  --max-span N           Skip quad candidates where max(pin)-min(pin) > N\n"
		"  --max-tests N          Stop after N motor sweeps/pulses\n"
		"  --skip-tests N         Skip first N generated tests before driving GPIOs\n"
		"  --enable-gpio N        Set motor power/enable GPIO before testing\n"
		"  --enable-value 0|1     Value for --enable-gpio (default: 1)\n"
		"  --pan-enable-gpio N    Pan motor enable GPIO for shared-coil tests\n"
		"  --tilt-enable-gpio N   Tilt motor enable GPIO for shared-coil tests\n"
		"  --axis pan|tilt        Select active axis when using axis enables\n"
		"  --allow-sdio-pins      Allow GPIO40-46/PB08-PB14 tests\n"
		"  --direct-sysfs         Use /sys/class/gpio directly instead of /sbin/gpio\n"
		"  --keep-motor-stack     Do not stop S59motor/motors-daemon/motor.ko first\n"
		"  -h, --help             Show this help\n"
		"\n"
		"Examples:\n"
		"  motor-gpio-scan --pins \"61 62 63 49\" --steps 96\n"
		"  motor-gpio-scan --pins \"61 62 63 49\" --permute --steps 32 --pause\n"
		"  motor-gpio-scan --scan-known --drive half --steps 48 --pause\n"
		"  motor-gpio-scan --pins \"51 54 57 38\" --axis pan --pan-enable-gpio 16 --tilt-enable-gpio 17 --drive half\n"
		"  motor-gpio-scan --quad-range 47-95 --max-span 12 --steps 32 --pause\n"
		"  motor-gpio-scan --quad-pins \"47 48 51 52 53 54 55 56 59 65 66\" --permute --steps 24 --pause\n"
		"  motor-gpio-scan --pair-range 47-95 --pulse-ms 150 --pause\n"
		"  motor-gpio-scan --pulse-range 32-95 --exclude \"49 50 58 60 61 62 63 64\" --pause\n");
}

static void die(const char *message)
{
	fprintf(stderr, "ERROR: %s\n", message);
	exit(EXIT_FAILURE);
}

static void die_errno(const char *message)
{
	fprintf(stderr, "ERROR: %s: %s\n", message, strerror(errno));
	exit(EXIT_FAILURE);
}

static int claim_test_slot(void)
{
	if (max_tests > 0 && tests_run >= max_tests)
		return 1;

	tests_seen++;
	if (skip_tests > 0 && tests_seen <= skip_tests)
		return 2;

	tests_run++;
	return 0;
}

static int parse_int(const char *value, int min, int max, int *out)
{
	char *end = NULL;
	long parsed;

	errno = 0;
	parsed = strtol(value, &end, 10);
	if (errno || !end || *end || parsed < min || parsed > max)
		return -1;

	*out = (int)parsed;
	return 0;
}

static int path_exists(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0;
}

static void sysfs_write(const char *path, const char *value, int required)
{
	int fd;
	ssize_t len;
	ssize_t wrote;

	fd = open(path, O_WRONLY);
	if (fd < 0) {
		if (required)
			die_errno(path);
		return;
	}

	len = (ssize_t)strlen(value);
	wrote = write(fd, value, len);
	close(fd);

	if (required && wrote != len)
		die_errno(path);
}

static void gpio_path(char *buf, size_t len, int pin, const char *leaf)
{
	snprintf(buf, len, GPIO_BASE "/gpio%d/%s", pin, leaf);
}

static int was_exported_by_us(int pin)
{
	size_t i;

	for (i = 0; i < exported_pins_count; i++) {
		if (exported_pins[i] == pin)
			return 1;
	}

	return 0;
}

static int gpio_helper_write(int pin, int value, int required)
{
	char command[96];
	int rc;

	snprintf(command, sizeof(command), "/sbin/gpio %s %d >/dev/null 2>&1",
		value ? "high" : "clear", pin);
	rc = system(command);
	if (rc != 0) {
		if (required)
			fprintf(stderr, "ERROR: /sbin/gpio %s %d failed\n",
				value ? "high" : "clear", pin);
		return -1;
	}

	return 0;
}

static void export_gpio(int pin)
{
	char path[128];
	char value[32];

	if (use_gpio_helper)
		return;

	snprintf(path, sizeof(path), GPIO_BASE "/gpio%d", pin);
	if (!path_exists(path)) {
		snprintf(value, sizeof(value), "%d", pin);
		sysfs_write(GPIO_BASE "/export", value, 1);

		if (exported_pins_count < ARRAY_SIZE(exported_pins))
			exported_pins[exported_pins_count++] = pin;
	}

	if (path_exists(GPIO_CLAIM_PATH)) {
		snprintf(value, sizeof(value), "%d", pin);
		sysfs_write(GPIO_CLAIM_PATH, value, 0);
	}

	gpio_path(path, sizeof(path), pin, "direction");
	sysfs_write(path, "out", 1);
}

static int map_bit(char bit)
{
	int value = bit == '1';

	if (invert_gpio)
		value = !value;

	return value;
}

static int off_value(void)
{
	return invert_gpio ? 1 : 0;
}

static int raw_write_gpio(int pin, int value, int required)
{
	char path[128];
	char text[4];

	if (use_gpio_helper)
		return gpio_helper_write(pin, value, required);

	gpio_path(path, sizeof(path), pin, "value");
	snprintf(text, sizeof(text), "%d", value);
	sysfs_write(path, text, required);
	return 0;
}

static void all_off(void)
{
	size_t i;

	if (!current_pins_valid)
		return;

	for (i = 0; i < ARRAY_SIZE(current_pins); i++)
		raw_write_gpio(current_pins[i], off_value(), 0);
}

static void disable_enable_gpio(void)
{
	char value[32];

	if (enable_gpio < 0)
		return;

	raw_write_gpio(enable_gpio, enable_value ? 0 : 1, 0);

	if (enable_exported) {
		snprintf(value, sizeof(value), "%d", enable_gpio);
		sysfs_write(GPIO_BASE "/unexport", value, 0);
	}
}

static void disable_axis_enable_gpios(void)
{
	char value[32];
	int inactive = enable_value ? 0 : 1;

	if (pan_enable_gpio >= 0)
		raw_write_gpio(pan_enable_gpio, inactive, 0);
	if (tilt_enable_gpio >= 0)
		raw_write_gpio(tilt_enable_gpio, inactive, 0);

	if (pan_enable_exported) {
		snprintf(value, sizeof(value), "%d", pan_enable_gpio);
		sysfs_write(GPIO_BASE "/unexport", value, 0);
	}
	if (tilt_enable_exported) {
		snprintf(value, sizeof(value), "%d", tilt_enable_gpio);
		sysfs_write(GPIO_BASE "/unexport", value, 0);
	}
}

static void release_exported_gpios(void)
{
	size_t i;
	char value[32];

	for (i = 0; i < exported_pins_count; i++) {
		if (!was_exported_by_us(exported_pins[i]))
			continue;

		snprintf(value, sizeof(value), "%d", exported_pins[i]);
		sysfs_write(GPIO_BASE "/unexport", value, 0);
	}
}

static void cleanup(void)
{
	all_off();
	disable_axis_enable_gpios();
	disable_enable_gpio();
	release_exported_gpios();
}

static void signal_cleanup(int sig)
{
	cleanup();
	signal(sig, SIG_DFL);
	raise(sig);
}

static void setup_enable_gpio(void)
{
	char path[128];
	char value[32];

	if (enable_gpio < 0)
		return;

	if (use_gpio_helper) {
		raw_write_gpio(enable_gpio, enable_value, 1);
		return;
	}

	snprintf(path, sizeof(path), GPIO_BASE "/gpio%d", enable_gpio);
	if (!path_exists(path)) {
		snprintf(value, sizeof(value), "%d", enable_gpio);
		sysfs_write(GPIO_BASE "/export", value, 1);
		enable_exported = 1;
	}

	if (path_exists(GPIO_CLAIM_PATH)) {
		snprintf(value, sizeof(value), "%d", enable_gpio);
		sysfs_write(GPIO_CLAIM_PATH, value, 0);
	}

	gpio_path(path, sizeof(path), enable_gpio, "direction");
	sysfs_write(path, "out", 1);
	raw_write_gpio(enable_gpio, enable_value, 1);
}

static void setup_one_axis_enable_gpio(int pin, int *exported)
{
	char path[128];
	char value[32];

	if (pin < 0)
		return;

	if (use_gpio_helper)
		return;

	snprintf(path, sizeof(path), GPIO_BASE "/gpio%d", pin);
	if (!path_exists(path)) {
		snprintf(value, sizeof(value), "%d", pin);
		sysfs_write(GPIO_BASE "/export", value, 1);
		*exported = 1;
	}

	if (path_exists(GPIO_CLAIM_PATH)) {
		snprintf(value, sizeof(value), "%d", pin);
		sysfs_write(GPIO_CLAIM_PATH, value, 0);
	}

	gpio_path(path, sizeof(path), pin, "direction");
	sysfs_write(path, "out", 1);
}

static void setup_axis_enable_gpios(void)
{
	int pan_active;
	int active = enable_value;
	int inactive = enable_value ? 0 : 1;

	if (pan_enable_gpio < 0 && tilt_enable_gpio < 0)
		return;

	if (strcmp(axis_arg, "pan") == 0) {
		pan_active = 1;
	} else if (strcmp(axis_arg, "tilt") == 0) {
		pan_active = 0;
	} else {
		die("--axis pan|tilt is required with --pan-enable-gpio/--tilt-enable-gpio");
	}

	if (use_gpio_helper) {
		if (pan_enable_gpio >= 0)
			raw_write_gpio(pan_enable_gpio, pan_active ? active : inactive, 1);
		if (tilt_enable_gpio >= 0)
			raw_write_gpio(tilt_enable_gpio, pan_active ? inactive : active, 1);
		return;
	}

	setup_one_axis_enable_gpio(pan_enable_gpio, &pan_enable_exported);
	setup_one_axis_enable_gpio(tilt_enable_gpio, &tilt_enable_exported);

	if (pan_enable_gpio >= 0)
		raw_write_gpio(pan_enable_gpio, pan_active ? active : inactive, 1);
	if (tilt_enable_gpio >= 0)
		raw_write_gpio(tilt_enable_gpio, pan_active ? inactive : active, 1);
}

static void trim(char *text)
{
	char *start = text;
	size_t len;

	while (*start && isspace((unsigned char)*start))
		start++;

	if (start != text)
		memmove(text, start, strlen(start) + 1);

	len = strlen(text);
	while (len > 0 && isspace((unsigned char)text[len - 1]))
		text[--len] = '\0';
}

static int parse_pin_list(const char *text, int pins[4])
{
	char buf[128];
	char *saveptr = NULL;
	char *token;
	int count = 0;

	if (strlen(text) >= sizeof(buf))
		return -1;

	strcpy(buf, text);
	for (token = strtok_r(buf, " ,\t\r\n", &saveptr);
		token;
		token = strtok_r(NULL, " ,\t\r\n", &saveptr)) {
		if (count >= 4)
			return -1;
		if (parse_int(token, 0, 255, &pins[count]) < 0)
			return -1;
		count++;
	}

	return count == 4 ? 0 : -1;
}

static int append_pin_tokens(const char *text, int *pins, size_t max_pins, size_t *pin_count)
{
	char buf[512];
	char *saveptr = NULL;
	char *token;

	if (strlen(text) >= sizeof(buf))
		return -1;

	strcpy(buf, text);
	for (token = strtok_r(buf, " ,\t\r\n", &saveptr);
		token;
		token = strtok_r(NULL, " ,\t\r\n", &saveptr)) {
		if (*pin_count >= max_pins)
			return -1;
		if (parse_int(token, 0, 255, &pins[*pin_count]) < 0)
			return -1;
		(*pin_count)++;
	}

	return 0;
}

static int parse_range(const char *text, int *start, int *end)
{
	char buf[64];
	char *dash;

	if (strlen(text) >= sizeof(buf))
		return -1;

	strcpy(buf, text);
	dash = strchr(buf, '-');
	if (!dash)
		return -1;

	*dash = '\0';
	dash++;

	if (parse_int(buf, 0, 255, start) < 0)
		return -1;
	if (parse_int(dash, 0, 255, end) < 0)
		return -1;

	return 0;
}

static int pin_is_in_list(const int *pins, size_t count, int pin)
{
	size_t i;

	for (i = 0; i < count; i++) {
		if (pins[i] == pin)
			return 1;
	}

	return 0;
}

static void sort_pins(int *pins, size_t count)
{
	size_t i;

	for (i = 1; i < count; i++) {
		int value = pins[i];
		size_t j = i;

		while (j > 0 && pins[j - 1] > value) {
			pins[j] = pins[j - 1];
			j--;
		}

		pins[j] = value;
	}
}

static int pin_is_excluded(int pin)
{
	int pins[128];
	size_t count = 0;
	size_t i;

	if (!exclude_arg[0])
		goto check_builtin_excludes;

	if (append_pin_tokens(exclude_arg, pins, ARRAY_SIZE(pins), &count) < 0)
		die("--exclude expects numeric GPIO pins");

	for (i = 0; i < count; i++) {
		if (pins[i] == pin)
			return 1;
	}

check_builtin_excludes:
	if (!allow_sdio_pins && pin >= 40 && pin <= 46)
		return 1;

	return 0;
}

static void append_unique_pin(int *pins, size_t max_pins, size_t *count, int pin)
{
	if (*count >= max_pins)
		die("too many GPIO pins in scan set");
	if (pin_is_in_list(pins, *count, pin))
		return;
	if (pin_is_excluded(pin))
		return;

	pins[(*count)++] = pin;
}

static void append_pin_range(const char *range_arg, int *pins, size_t max_pins,
			     size_t *count)
{
	int start;
	int end;
	int step;
	int pin;

	if (parse_range(range_arg, &start, &end) < 0)
		die("range argument expects A-B");

	step = start <= end ? 1 : -1;
	for (pin = start;; pin += step) {
		append_unique_pin(pins, max_pins, count, pin);
		if (pin == end)
			break;
	}
}

static void append_pin_list_filtered(const char *text, int *pins, size_t max_pins,
				     size_t *count)
{
	int parsed[256];
	size_t parsed_count = 0;
	size_t i;

	if (append_pin_tokens(text, parsed, ARRAY_SIZE(parsed), &parsed_count) < 0)
		die("pin list expects numeric GPIO pins");

	for (i = 0; i < parsed_count; i++)
		append_unique_pin(pins, max_pins, count, parsed[i]);
}

static void stop_motor_stack(void)
{
	int rc;

	if (keep_motor_stack)
		return;

	rc = system("killall motors-daemon >/dev/null 2>&1 || true");
	if (rc == -1)
		fprintf(stderr, "warning: could not run killall motors-daemon\n");

	rc = system("for i in 1 2 3; do pidof motors-daemon >/dev/null 2>&1 || exit 0; sleep 1; done; exit 1");
	if (rc != 0) {
		fprintf(stderr,
			"warning: motors-daemon is still running; not unloading motor.ko\n");
		return;
	}

	rc = system("rmmod motor >/dev/null 2>&1");
	if (rc != 0)
		fprintf(stderr, "warning: motor.ko was not unloaded; continuing with raw GPIO test\n");
}

static void read_pins_from_config(void)
{
	FILE *fp;
	char command[160];
	const char *key;

	if (strcmp(from_config, "pan") == 0)
		key = "motors.gpio_pan";
	else if (strcmp(from_config, "tilt") == 0)
		key = "motors.gpio_tilt";
	else
		die("--from-config expects pan or tilt");

	snprintf(command, sizeof(command), "jct " MOTORS_CONFIG " get %s 2>/dev/null", key);
	fp = popen(command, "r");
	if (!fp)
		die_errno("popen jct");

	if (!fgets(pins_arg, sizeof(pins_arg), fp)) {
		pclose(fp);
		die("could not read pins from motors.json");
	}

	pclose(fp);
	trim(pins_arg);
	if (!pins_arg[0])
		die("empty pin list in motors.json");
}

static int prepare_pins(const int pins[4])
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(current_pins); i++)
		current_pins[i] = pins[i];
	current_pins_valid = 1;

	for (i = 0; i < ARRAY_SIZE(current_pins); i++)
		export_gpio(current_pins[i]);

	for (i = 0; i < ARRAY_SIZE(current_pins); i++) {
		if (raw_write_gpio(current_pins[i], off_value(), 0) < 0)
			return -1;
	}

	return 0;
}

static const char **get_sequence(size_t *count)
{
	switch (drive) {
	case DRIVE_WAVE:
		*count = ARRAY_SIZE(wave_sequence);
		return wave_sequence;
	case DRIVE_FULL:
		*count = ARRAY_SIZE(full_sequence);
		return full_sequence;
	case DRIVE_HALF:
		*count = ARRAY_SIZE(half_sequence);
		return half_sequence;
	}

	die("invalid drive mode");
	return NULL;
}

static const char *drive_name(void)
{
	switch (drive) {
	case DRIVE_WAVE:
		return "wave";
	case DRIVE_FULL:
		return "full";
	case DRIVE_HALF:
		return "half";
	}

	return "unknown";
}

static void pause_if_requested(void);

static int apply_pattern(const char *pattern)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(current_pins); i++) {
		if (raw_write_gpio(current_pins[i], map_bit(pattern[i]), 1) < 0)
			return -1;
	}

	return 0;
}

static int run_sweep(const char *pin_text, const char *label)
{
	int pins[4];
	const char **sequence;
	size_t sequence_count;
	int count = 0;
	int slot;

	if (max_tests > 0 && tests_run >= max_tests)
		return 1;

	if (parse_pin_list(pin_text, pins) < 0)
		die("expected exactly four numeric GPIO pins");

	if (pin_is_excluded(pins[0]) || pin_is_excluded(pins[1]) ||
	    pin_is_excluded(pins[2]) || pin_is_excluded(pins[3]))
		return -1;

	if (pins[0] == pins[1] || pins[0] == pins[2] || pins[0] == pins[3] ||
	    pins[1] == pins[2] || pins[1] == pins[3] || pins[2] == pins[3])
		return -1;

	slot = claim_test_slot();
	if (slot != 0)
		return slot;

	if (prepare_pins(pins) < 0) {
		fprintf(stderr, "Skipping %s: pins='%d %d %d %d' are not all usable as outputs\n",
			label, pins[0], pins[1], pins[2], pins[3]);
		all_off();
		return -1;
	}
	sequence = get_sequence(&sequence_count);

	printf("[%d] Testing %s: pins='%d %d %d %d' api=%s drive=%s steps=%d delay_us=%d invert=%d reverse=%d\n",
		tests_seen, label, pins[0], pins[1], pins[2], pins[3],
		use_gpio_helper ? "gpio-helper" : "direct-sysfs",
		drive_name(), steps, delay_us, invert_gpio, reverse_sequence);
	fflush(stdout);

	while (count < steps) {
		size_t i;

		for (i = 0; i < sequence_count && count < steps; i++) {
			size_t index = reverse_sequence ? sequence_count - 1 - i : i;
			if (apply_pattern(sequence[index]) < 0) {
				fprintf(stderr, "Stopping %s: GPIO write failed\n", label);
				all_off();
				return -1;
			}
			usleep((useconds_t)delay_us);
			count++;
		}
	}

	all_off();
	return 0;
}

static int run_sweep_pins(const int pins[4], const char *label)
{
	char candidate[64];

	snprintf(candidate, sizeof(candidate), "%d %d %d %d",
		pins[0], pins[1], pins[2], pins[3]);
	return run_sweep(candidate, label);
}

static int run_candidate_orders(const int pins[4], const char *base_label)
{
	if (!permute_pins) {
		int rc = run_sweep_pins(pins, base_label);

		if (rc == 0)
			pause_if_requested();
		return max_tests > 0 && tests_run >= max_tests;
	}

	{
		int idx = 0;
		size_t a;

		for (a = 0; a < ARRAY_SIZE(current_pins); a++) {
			size_t b;
			for (b = 0; b < ARRAY_SIZE(current_pins); b++) {
				size_t c;
				if (a == b)
					continue;
				for (c = 0; c < ARRAY_SIZE(current_pins); c++) {
					size_t d;
					if (a == c || b == c)
						continue;
					for (d = 0; d < ARRAY_SIZE(current_pins); d++) {
						int ordered[4];
						char label[128];
						int rc;

						if (a == d || b == d || c == d)
							continue;

						idx++;
						ordered[0] = pins[a];
						ordered[1] = pins[b];
						ordered[2] = pins[c];
						ordered[3] = pins[d];
						snprintf(label, sizeof(label), "%s permutation %d/24",
							base_label, idx);
						rc = run_sweep_pins(ordered, label);
						if (rc == 0)
							pause_if_requested();
						if (max_tests > 0 && tests_run >= max_tests)
							return 1;
					}
				}
			}
		}
	}

	return 0;
}

static void pause_if_requested(void)
{
	int ch;

	if (!pause_between)
		return;

	fprintf(stderr, "Press Enter for next candidate, or Ctrl-C to stop: ");
	fflush(stderr);
	do {
		ch = getchar();
	} while (ch != '\n' && ch != EOF);
}

static int pulse_pin(int pin)
{
	int slot;

	if (pin_is_excluded(pin)) {
		printf("Skipping gpio%d: excluded\n", pin);
		return 0;
	}

	if (max_tests > 0 && tests_run >= max_tests)
		return 1;

	slot = claim_test_slot();
	if (slot != 0)
		return slot;

	if (!use_gpio_helper)
		export_gpio(pin);

	printf("[%d] Pulsing gpio%d for %d ms using %s\n",
		tests_seen, pin, pulse_ms,
		use_gpio_helper ? "gpio-helper" : "direct-sysfs");
	fflush(stdout);

	if (raw_write_gpio(pin, off_value(), 0) < 0)
		return -1;
	usleep(10000);
	if (raw_write_gpio(pin, map_bit('1'), 0) < 0)
		return -1;
	usleep((useconds_t)pulse_ms * 1000);
	if (raw_write_gpio(pin, off_value(), 0) < 0)
		return -1;

	return 0;
}

static void run_pulse_discovery(void)
{
	int pins[256];
	size_t count = 0;
	size_t i;

	if (pulse_range_arg[0]) {
		int start;
		int end;
		int step;
		int pin;

		if (parse_range(pulse_range_arg, &start, &end) < 0)
			die("--pulse-range expects A-B");

		step = start <= end ? 1 : -1;
		for (pin = start;; pin += step) {
			if (count >= ARRAY_SIZE(pins))
				die("too many pins in pulse range");
			pins[count++] = pin;
			if (pin == end)
				break;
		}
	}

	if (pulse_pins_arg[0]) {
		if (append_pin_tokens(pulse_pins_arg, pins, ARRAY_SIZE(pins), &count) < 0)
			die("--pulse-pins expects numeric GPIO pins");
	}

	if (count == 0)
		die("--pulse-range or --pulse-pins is required for pulse mode");

	for (i = 0; i < count; i++) {
		int rc = pulse_pin(pins[i]);

		if (rc < 0)
			fprintf(stderr, "Skipping gpio%d: write failed\n", pins[i]);
		if (rc == 0)
			pause_if_requested();
		if (max_tests > 0 && tests_run >= max_tests)
			return;
	}
}

static int pair_pulse(int pin_a, int pin_b)
{
	int slot;

	if (pin_is_excluded(pin_a) || pin_is_excluded(pin_b)) {
		printf("Skipping gpio%d,gpio%d: excluded\n", pin_a, pin_b);
		return 0;
	}

	if (pin_a == pin_b)
		return 0;

	if (max_tests > 0 && tests_run >= max_tests)
		return 1;

	slot = claim_test_slot();
	if (slot != 0)
		return slot;

	if (!use_gpio_helper) {
		export_gpio(pin_a);
		export_gpio(pin_b);
	}

	printf("[%d] Pair pulse gpio%d,gpio%d for %d ms using %s\n",
		tests_seen, pin_a, pin_b, pulse_ms,
		use_gpio_helper ? "gpio-helper" : "direct-sysfs");
	fflush(stdout);

	raw_write_gpio(pin_a, off_value(), 0);
	raw_write_gpio(pin_b, off_value(), 0);
	usleep(10000);
	if (raw_write_gpio(pin_a, map_bit('1'), 0) < 0 ||
	    raw_write_gpio(pin_b, map_bit('1'), 0) < 0) {
		raw_write_gpio(pin_a, off_value(), 0);
		raw_write_gpio(pin_b, off_value(), 0);
		return -1;
	}
	usleep((useconds_t)pulse_ms * 1000);
	raw_write_gpio(pin_a, off_value(), 0);
	raw_write_gpio(pin_b, off_value(), 0);

	return 0;
}

static void build_filtered_pin_set(const char *range_arg, const char *pins_arg,
				   int *pins, size_t max_pins, size_t *count)
{
	*count = 0;

	if (range_arg[0])
		append_pin_range(range_arg, pins, max_pins, count);
	if (pins_arg[0])
		append_pin_list_filtered(pins_arg, pins, max_pins, count);

	sort_pins(pins, *count);
}

static void print_pin_set(const char *label, const int *pins, size_t count)
{
	size_t i;

	printf("%s (%zu pins):", label, count);
	for (i = 0; i < count; i++)
		printf(" %d", pins[i]);
	putchar('\n');
}

static void run_pair_discovery(void)
{
	int pins[256];
	size_t count = 0;
	size_t i;

	build_filtered_pin_set(pair_range_arg, pair_pins_arg, pins, ARRAY_SIZE(pins),
			       &count);
	if (count < 2)
		die("--pair-range/--pair-pins produced fewer than two usable pins");

	print_pin_set("Pair scan pins", pins, count);

	for (i = 0; i < count; i++) {
		size_t j;
		for (j = i + 1; j < count; j++) {
			int rc = pair_pulse(pins[i], pins[j]);

			if (rc < 0)
				fprintf(stderr, "Skipping gpio%d,gpio%d: write failed\n",
					pins[i], pins[j]);
			if (rc == 0)
				pause_if_requested();
			if (max_tests > 0 && tests_run >= max_tests)
				return;
		}
	}
}

static void run_quad_discovery(void)
{
	int pins[256];
	size_t count = 0;
	size_t i;

	build_filtered_pin_set(quad_range_arg, quad_pins_arg, pins, ARRAY_SIZE(pins),
			       &count);
	if (count < 4)
		die("--quad-range/--quad-pins produced fewer than four usable pins");

	print_pin_set("Quad scan pins", pins, count);
	if (max_span > 0)
		printf("Skipping candidates with span > %d\n", max_span);

	for (i = 0; i < count; i++) {
		size_t j;
		for (j = i + 1; j < count; j++) {
			size_t k;
			for (k = j + 1; k < count; k++) {
				size_t l;
				for (l = k + 1; l < count; l++) {
					int candidate[4];
					char label[96];

					if (max_span > 0 && pins[l] - pins[i] > max_span)
						continue;

					candidate[0] = pins[i];
					candidate[1] = pins[j];
					candidate[2] = pins[k];
					candidate[3] = pins[l];
					snprintf(label, sizeof(label), "quad set %d %d %d %d",
						candidate[0], candidate[1],
						candidate[2], candidate[3]);
					if (run_candidate_orders(candidate, label))
						return;
				}
			}
		}
	}
}

static void run_candidate_file(void)
{
	FILE *fp;
	char line[256];
	int line_no = 0;

	fp = fopen(candidate_file_arg, "r");
	if (!fp)
		die_errno(candidate_file_arg);

	while (fgets(line, sizeof(line), fp)) {
		char *comment;
		int pins[4];
		char label[320];

		line_no++;
		comment = strchr(line, '#');
		if (comment)
			*comment = '\0';
		trim(line);
		if (!line[0])
			continue;

		if (parse_pin_list(line, pins) < 0) {
			fprintf(stderr, "Skipping %s:%d: expected four GPIO pins\n",
				candidate_file_arg, line_no);
			continue;
		}

		snprintf(label, sizeof(label), "%s:%d", candidate_file_arg, line_no);
		if (run_candidate_orders(pins, label))
			break;
	}

	fclose(fp);
}

static void run_permutations(const char *pin_text)
{
	int pins[4];

	if (parse_pin_list(pin_text, pins) < 0)
		die("expected exactly four numeric GPIO pins");

	run_candidate_orders(pins, "supplied order");
}

static void run_known_candidates(void)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(known_candidates); i++) {
		if (run_sweep(known_candidates[i].pins, known_candidates[i].label) == 0)
			pause_if_requested();
	}
}

static void parse_args(int argc, char **argv)
{
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--pins") == 0) {
			if (++i >= argc)
				die("--pins requires an argument");
			snprintf(pins_arg, sizeof(pins_arg), "%s", argv[i]);
		} else if (strcmp(argv[i], "--from-config") == 0) {
			if (++i >= argc)
				die("--from-config requires pan or tilt");
			snprintf(from_config, sizeof(from_config), "%s", argv[i]);
		} else if (strcmp(argv[i], "--steps") == 0) {
			if (++i >= argc || parse_int(argv[i], 1, 100000, &steps) < 0)
				die("--steps must be a positive number");
		} else if (strcmp(argv[i], "--delay-us") == 0) {
			if (++i >= argc || parse_int(argv[i], 1, 1000000, &delay_us) < 0)
				die("--delay-us must be a positive number");
		} else if (strcmp(argv[i], "--pulse-ms") == 0) {
			if (++i >= argc || parse_int(argv[i], 1, 10000, &pulse_ms) < 0)
				die("--pulse-ms must be a positive number");
		} else if (strcmp(argv[i], "--drive") == 0) {
			if (++i >= argc)
				die("--drive requires wave, full, or half");
			if (strcmp(argv[i], "wave") == 0)
				drive = DRIVE_WAVE;
			else if (strcmp(argv[i], "full") == 0)
				drive = DRIVE_FULL;
			else if (strcmp(argv[i], "half") == 0)
				drive = DRIVE_HALF;
			else
				die("--drive requires wave, full, or half");
		} else if (strcmp(argv[i], "--reverse") == 0) {
			reverse_sequence = 1;
		} else if (strcmp(argv[i], "--invert") == 0) {
			invert_gpio = 1;
		} else if (strcmp(argv[i], "--permute") == 0) {
			permute_pins = 1;
		} else if (strcmp(argv[i], "--pause") == 0) {
			pause_between = 1;
		} else if (strcmp(argv[i], "--scan-known") == 0) {
			scan_known = 1;
		} else if (strcmp(argv[i], "--quad-range") == 0) {
			if (++i >= argc)
				die("--quad-range requires A-B");
			snprintf(quad_range_arg, sizeof(quad_range_arg), "%s", argv[i]);
			quad_mode = 1;
		} else if (strcmp(argv[i], "--quad-pins") == 0) {
			if (++i >= argc)
				die("--quad-pins requires a pin list");
			snprintf(quad_pins_arg, sizeof(quad_pins_arg), "%s", argv[i]);
			quad_mode = 1;
		} else if (strcmp(argv[i], "--candidate-file") == 0) {
			if (++i >= argc)
				die("--candidate-file requires a path");
			snprintf(candidate_file_arg, sizeof(candidate_file_arg), "%s", argv[i]);
			quad_mode = 1;
		} else if (strcmp(argv[i], "--pair-range") == 0) {
			if (++i >= argc)
				die("--pair-range requires A-B");
			snprintf(pair_range_arg, sizeof(pair_range_arg), "%s", argv[i]);
			pair_mode = 1;
		} else if (strcmp(argv[i], "--pair-pins") == 0) {
			if (++i >= argc)
				die("--pair-pins requires a pin list");
			snprintf(pair_pins_arg, sizeof(pair_pins_arg), "%s", argv[i]);
			pair_mode = 1;
		} else if (strcmp(argv[i], "--pulse-range") == 0) {
			if (++i >= argc)
				die("--pulse-range requires A-B");
			snprintf(pulse_range_arg, sizeof(pulse_range_arg), "%s", argv[i]);
			pulse_mode = 1;
		} else if (strcmp(argv[i], "--pulse-pins") == 0) {
			if (++i >= argc)
				die("--pulse-pins requires a pin list");
			snprintf(pulse_pins_arg, sizeof(pulse_pins_arg), "%s", argv[i]);
			pulse_mode = 1;
		} else if (strcmp(argv[i], "--exclude") == 0) {
			if (++i >= argc)
				die("--exclude requires a pin list");
			snprintf(exclude_arg, sizeof(exclude_arg), "%s", argv[i]);
		} else if (strcmp(argv[i], "--max-span") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 255, &max_span) < 0)
				die("--max-span must be 0..255");
		} else if (strcmp(argv[i], "--max-tests") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 1000000, &max_tests) < 0)
				die("--max-tests must be 0..1000000");
		} else if (strcmp(argv[i], "--skip-tests") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 1000000, &skip_tests) < 0)
				die("--skip-tests must be 0..1000000");
		} else if (strcmp(argv[i], "--enable-gpio") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 255, &enable_gpio) < 0)
				die("--enable-gpio must be a GPIO number");
		} else if (strcmp(argv[i], "--enable-value") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 1, &enable_value) < 0)
				die("--enable-value must be 0 or 1");
		} else if (strcmp(argv[i], "--pan-enable-gpio") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 255, &pan_enable_gpio) < 0)
				die("--pan-enable-gpio must be a GPIO number");
		} else if (strcmp(argv[i], "--tilt-enable-gpio") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 255, &tilt_enable_gpio) < 0)
				die("--tilt-enable-gpio must be a GPIO number");
		} else if (strcmp(argv[i], "--axis") == 0) {
			if (++i >= argc)
				die("--axis requires pan or tilt");
			snprintf(axis_arg, sizeof(axis_arg), "%s", argv[i]);
		} else if (strcmp(argv[i], "--allow-sdio-pins") == 0) {
			allow_sdio_pins = 1;
		} else if (strcmp(argv[i], "--direct-sysfs") == 0) {
			use_gpio_helper = 0;
		} else if (strcmp(argv[i], "--keep-motor-stack") == 0) {
			keep_motor_stack = 1;
		} else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			usage(stdout);
			exit(EXIT_SUCCESS);
		} else {
			usage(stderr);
			exit(EXIT_FAILURE);
		}
	}
}

int main(int argc, char **argv)
{
	parse_args(argc, argv);

	if (geteuid() != 0)
		die("must run as root");

	if (!path_exists(GPIO_BASE))
		die("missing " GPIO_BASE);

	if (from_config[0])
		read_pins_from_config();

	if (!scan_known && !pulse_mode && !quad_mode && !pair_mode && !pins_arg[0]) {
		usage(stderr);
		return EXIT_FAILURE;
	}

	atexit(cleanup);
	signal(SIGINT, signal_cleanup);
	signal(SIGTERM, signal_cleanup);

	stop_motor_stack();
	setup_enable_gpio();
	setup_axis_enable_gpios();

	if (pulse_mode)
		run_pulse_discovery();
	else if (pair_mode)
		run_pair_discovery();
	else if (candidate_file_arg[0])
		run_candidate_file();
	else if (quad_mode)
		run_quad_discovery();
	else if (scan_known)
		run_known_candidates();
	else if (permute_pins)
		run_permutations(pins_arg);
	else
		return run_sweep(pins_arg, "supplied order") == 0 ? EXIT_SUCCESS : EXIT_FAILURE;

	return EXIT_SUCCESS;
}
