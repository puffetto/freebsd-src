// File: tools/test/md_preload/md_preload_test.c
// Created by Andrea "Nemesi" Cocito on 15/10/2026
// Disposable-guest regression consumer of the md preload borrowing API.
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/linker.h>
#include <sys/malloc.h>
#include <sys/mdioctl.h>
#include <sys/module.h>
#include <sys/sysctl.h>
#include <geom/geom.h>
#include <vm/vm.h>
#include <vm/pmap.h>

static struct g_consumer *consumers[3];
static unsigned holds[2];
static int state;

static void
test_orphan(struct g_consumer *cp)
{

	panic("md_preload_test: active consumer orphaned: %s", cp->geom->name);
}

static struct g_class test_class = {
	.name = "MD_PRELOAD_TEST",
	.version = G_VERSION,
	.orphan = test_orphan,
};
DECLARE_GEOM_CLASS(test_class, md_preload_test);
MODULE_DEPEND(md_preload_test, geom_md, 0, 0, 0);

static void
test_close(void)
{
	struct g_consumer *cp;
	struct g_geom *gp;
	unsigned i;

	g_topology_assert();
	for (i = 0; i < nitems(consumers); i++) {
		cp = consumers[i];
		if (cp == NULL)
			continue;
		if (i < nitems(holds)) {
			while (holds[i] != 0) {
				md_preload_release(cp);
				holds[i]--;
			}
		}
		if (cp->acr || cp->acw || cp->ace)
			(void)g_access(cp, -cp->acr, -cp->acw, -cp->ace);
		if (cp->provider != NULL)
			g_detach(cp);
		gp = cp->geom;
		g_destroy_consumer(cp);
		g_destroy_geom(gp);
		consumers[i] = NULL;
	}
	state = 0;
}

#define CHECK(expr) do { \
	if (!(expr)) { \
		printf("MD_PRELOAD FAIL line %d: %s\n", __LINE__, #expr); \
		test_close(); \
		return (EIO); \
	} \
} while (0)

static int
test_hold(void)
{
	struct g_consumer *cp;
	struct g_provider *pp;
	const void *base, *again, *first = NULL;
	caddr_t mod;
	size_t size, again_size;
	char name[32];
	unsigned i;

	g_topology_assert();
	for (i = 0; i < nitems(consumers); i++) {
		snprintf(name, sizeof(name), "md%u", i);
		pp = g_provider_by_name(name);
		CHECK(pp != NULL);
		cp = g_new_consumer(g_new_geomf(&test_class, "mdpreload.%u", i));
		consumers[i] = cp;
		base = NULL;
		size = 0;
		CHECK(md_preload_hold(cp, &base, &size) == EOPNOTSUPP);
		CHECK(g_attach(cp, pp) == 0);
		if (i == 2) {
			/* md2 is an ordinary malloc device, created by the guest. */
			CHECK(g_access(cp, 1, 0, 1) == 0);
			CHECK(md_preload_hold(cp, &base, &size) == EOPNOTSUPP);
			CHECK(base == NULL && size == 0);
			continue;
		}
		CHECK(md_preload_hold(cp, &base, &size) == EBUSY);
		CHECK(g_access(cp, 1, 0, 0) == 0);
		CHECK(md_preload_hold(cp, &base, &size) == EBUSY);
		CHECK(g_access(cp, 0, 1, 1) == 0);
		CHECK(md_preload_hold(cp, &base, &size) == EBUSY);
		CHECK(g_access(cp, 0, -1, 0) == 0);
		CHECK(base == NULL && size == 0);
		CHECK(md_preload_hold(cp, &base, &size) == 0);
		holds[i]++;
		snprintf(name, sizeof(name), "/boot/mdtest%u.img", i);
		mod = preload_search_by_name(name);
		CHECK(mod != NULL);
		CHECK(base == preload_fetch_addr(mod));
		CHECK(size == preload_fetch_size(mod));
		CHECK(size >= PAGE_SIZE && size % PAGE_SIZE == 0);
		CHECK(((const u_char *)base)[0] == 'A' + i);
		CHECK(((const u_char *)base)[size - 1] == 'A' + i);
		CHECK(base != first);
		first = base;
		CHECK(md_preload_hold(cp, &again, &again_size) == 0);
		holds[i]++;
		CHECK(again == base && again_size == size);
		/* Same-consumer writes exercise md's check, beyond GEOM exclusivity. */
		CHECK(g_access(cp, 0, 1, 0) == EBUSY);
		printf("MD_PRELOAD PASS md%u: original=%p physical=%jx bytes=%zu holds=2\n",
		    i, base, (uintmax_t)pmap_kextract((vm_offset_t)base), size);
	}
	state = 1;
	return (0);
}

static int
test_control(SYSCTL_HANDLER_ARGS)
{
	int action, error;
	unsigned i;

	g_topology_lock();
	action = state;
	g_topology_unlock();
	error = sysctl_handle_int(oidp, &action, 0, req);
	if (error != 0 || req->newptr == NULL)
		return (error);
	g_topology_lock();
	if (action == 1 && state == 0) {
		error = test_hold();
	} else if (action == 2 && state == 1) {
		for (i = 0; i < nitems(holds); i++) {
			md_preload_release(consumers[i]);
			holds[i]--;
		}
		state = 2;
	} else if (action == 0) {
		test_close();
	} else {
		error = EINVAL;
	}
	g_topology_unlock();
	return (error);
}
SYSCTL_PROC(_debug, OID_AUTO, md_preload_test,
    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, test_control, "I",
    "Guest test: 1 acquires nested holds, 2 drops one, 0 releases all access");
// END File: tools/test/md_preload/md_preload_test.c
