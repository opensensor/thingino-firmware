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
	{"t23 y4/cp80x0 pan guess", "61 62 63 49"},
	{"t23 y4/cp80x0 tilt guess", "59 52 53 64"},
	{"d1/q5/q7 pan guess", "49 63 62 61"},
	{"d1/q5/q7 tilt guess", "52 53 64 59"},
	{"w7/y4-t31 pan guess", "49 61 62 63"},
	{"w7/y4-t31 tilt guess", "52 59 64 53"},
};

static int current_pins[4] = {-1, -1, -1, -1};
static int current_pins_valid;
static int exported_pins[16];
static size_t exported_pins_count;
static int enable_gpio = -1;
static int enable_value = 1;
static int enable_exported;
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
static int keep_motor_stack;
static int allow_sdio_pins;
static char pins_arg[128];
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
		"  --exclude \"p1 p2 ...\" Skip pins during --pulse-range/--pulse-pins\n"
		"  --enable-gpio N        Set motor power/enable GPIO before testing\n"
		"  --enable-value 0|1     Value for --enable-gpio (default: 1)\n"
		"  --allow-sdio-pins      Allow GPIO40-46/PB08-PB14 pulse tests\n"
		"  --direct-sysfs         Use /sys/class/gpio directly instead of /sbin/gpio\n"
		"  --keep-motor-stack     Do not stop S59motor/motors-daemon/motor.ko first\n"
		"  -h, --help             Show this help\n"
		"\n"
		"Examples:\n"
		"  motor-gpio-scan --pins \"61 62 63 49\" --steps 96\n"
		"  motor-gpio-scan --pins \"61 62 63 49\" --permute --steps 32 --pause\n"
		"  motor-gpio-scan --scan-known --drive half --steps 48 --pause\n"
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
	if (pulse_mode && !allow_sdio_pins && pin >= 40 && pin <= 46)
		return 1;

	return 0;
}

static void stop_motor_stack(void)
{
	int rc;

	if (keep_motor_stack)
		return;

	rc = system("/etc/init.d/S59motor stop >/dev/null 2>&1");
	if (rc == -1)
		fprintf(stderr, "warning: could not run S59motor stop\n");

	rc = system("killall motors-daemon >/dev/null 2>&1");
	if (rc == -1)
		fprintf(stderr, "warning: could not run killall motors-daemon\n");

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

	if (parse_pin_list(pin_text, pins) < 0)
		die("expected exactly four numeric GPIO pins");

	if (prepare_pins(pins) < 0) {
		fprintf(stderr, "Skipping %s: pins='%d %d %d %d' are not all usable as outputs\n",
			label, pins[0], pins[1], pins[2], pins[3]);
		all_off();
		return -1;
	}
	sequence = get_sequence(&sequence_count);

	printf("Testing %s: pins='%d %d %d %d' api=%s drive=%s steps=%d delay_us=%d invert=%d reverse=%d\n",
		label, pins[0], pins[1], pins[2], pins[3],
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
	if (pin_is_excluded(pin)) {
		printf("Skipping gpio%d: excluded\n", pin);
		return 0;
	}

	if (!use_gpio_helper)
		export_gpio(pin);

	printf("Pulsing gpio%d for %d ms using %s\n",
		pin, pulse_ms, use_gpio_helper ? "gpio-helper" : "direct-sysfs");
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
		if (pulse_pin(pins[i]) < 0)
			fprintf(stderr, "Skipping gpio%d: write failed\n", pins[i]);
		pause_if_requested();
	}
}

static void run_permutations(const char *pin_text)
{
	int pins[4];
	int idx = 0;
	size_t a;

	if (parse_pin_list(pin_text, pins) < 0)
		die("expected exactly four numeric GPIO pins");

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
					char candidate[64];
					char label[64];

					if (a == d || b == d || c == d)
						continue;

					idx++;
					snprintf(candidate, sizeof(candidate), "%d %d %d %d",
						pins[a], pins[b], pins[c], pins[d]);
					snprintf(label, sizeof(label), "permutation %d/24", idx);
					if (run_sweep(candidate, label) == 0)
						pause_if_requested();
				}
			}
		}
	}
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
		} else if (strcmp(argv[i], "--enable-gpio") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 255, &enable_gpio) < 0)
				die("--enable-gpio must be a GPIO number");
		} else if (strcmp(argv[i], "--enable-value") == 0) {
			if (++i >= argc || parse_int(argv[i], 0, 1, &enable_value) < 0)
				die("--enable-value must be 0 or 1");
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

	if (!scan_known && !pulse_mode && !pins_arg[0]) {
		usage(stderr);
		return EXIT_FAILURE;
	}

	atexit(cleanup);
	signal(SIGINT, signal_cleanup);
	signal(SIGTERM, signal_cleanup);

	stop_motor_stack();
	setup_enable_gpio();

	if (pulse_mode)
		run_pulse_discovery();
	else if (scan_known)
		run_known_candidates();
	else if (permute_pins)
		run_permutations(pins_arg);
	else
		return run_sweep(pins_arg, "supplied order") == 0 ? EXIT_SUCCESS : EXIT_FAILURE;

	return EXIT_SUCCESS;
}
