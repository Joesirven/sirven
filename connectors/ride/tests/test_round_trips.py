"""quote, book, track, and cancel round trips against the fake backends. every payload is checked
against the contract schema by ConnectorCase.call."""

import unittest
from datetime import timedelta

from helpers import BARBER_POINT, OFFICE_POINT, ConnectorCase, quote_arguments, usd, window
from ride_connector.backend import BackendError
from ride_connector.fake import FakeClock, demo_connector
from ride_connector.gateway import CONCIERGE_DISCLOSURE


class QuoteTests(ConnectorCase, unittest.TestCase):
    def test_options_are_ranked_densely_from_one(self):
        payload = self.quote()
        self.assertGreater(len(payload["options"]), 1)
        self.assertEqual(list(range(1, len(payload["options"]) + 1)), [o["rank"] for o in payload["options"]])
        self.assertEqual([], payload["notices"])

    def test_preferred_provider_ranks_first(self):
        payload = self.quote(preferred_providers=["Waymo"])
        self.assertEqual("Waymo", payload["options"][0]["provider"])
        for option in payload["options"][1:]:
            self.assertIn("provider_not_preferred", option["constraint_flags"])

    def test_cheapest_ranking_orders_by_authorization_cap(self):
        payload = self.quote(ranking="cheapest")
        caps = [o["charge_terms"]["authorization_cap"]["amount_minor"] for o in payload["options"] if o["bookable"]]
        self.assertEqual(sorted(caps), caps)

    def test_charge_terms_add_up(self):
        for option in self.quote(tip_ceiling_percent=10)["options"]:
            terms = option["charge_terms"]
            self.assertEqual(option["price"]["amount"], terms["quoted_amount"])
            self.assertEqual(option["price"]["maximum"], terms["fare_ceiling"])
            self.assertEqual(terms["fare_ceiling"]["amount_minor"] + terms["tip_ceiling"]["amount_minor"],
                             terms["authorization_cap"]["amount_minor"])
            self.assertTrue(all(terms[k]["currency"] == terms["currency"]
                                for k in ("quoted_amount", "fare_ceiling", "tip_ceiling", "authorization_cap")))

    def test_no_tip_ceiling_where_tips_are_not_taken(self):
        waymo = self.first(self.quote(), "Waymo")
        self.assertEqual(0, waymo["charge_terms"]["tip_ceiling"]["amount_minor"])

    def test_budget_counts_the_tip_ceiling(self):
        # pick a budget that covers a fare but not fare plus tip ceiling.
        open_quote = self.quote(tip_ceiling_percent=50)
        lyft = self.first(open_quote, "Lyft")
        budget = lyft["charge_terms"]["fare_ceiling"]["amount_minor"] + 1
        tight = self.quote(budget=budget, tip_ceiling_percent=50)
        for option in tight["options"]:
            over = option["charge_terms"]["authorization_cap"]["amount_minor"] > budget
            self.assertEqual(over, "over_budget" in option["constraint_flags"])
            self.assertEqual(not over, option["bookable"])

    def test_unbookable_options_rank_last(self):
        payload = self.quote(budget=1500)
        seen_unbookable = False
        for option in payload["options"]:
            seen_unbookable = seen_unbookable or not option["bookable"]
            if seen_unbookable:
                self.assertFalse(option["bookable"])

    def test_avoided_providers_are_left_out(self):
        payload = self.quote(avoided_providers=["uber"])
        self.assertNotIn("Uber", {o["provider"] for o in payload["options"]})

    def test_accessibility_needs_are_hard_requirements(self):
        payload = self.quote(accessibility_needs=["wheelchair_accessible"])
        for option in payload["options"]:
            meets = option["vehicle_class"] == "accessible"
            self.assertEqual(not meets, "accessibility_not_met" in option["constraint_flags"])
            self.assertEqual(meets, option["bookable"])

    def test_estimates_and_human_assistance_are_flagged(self):
        for option in self.quote()["options"]:
            self.assertEqual(option["price"]["kind"] == "estimate", "price_is_estimate" in option["constraint_flags"])
            human = option["fulfillment"]["method"] == "human_assisted"
            self.assertEqual(human, "human_assisted" in option["constraint_flags"])
            self.assertEqual(CONCIERGE_DISCLOSURE if human else None, option["fulfillment"]["disclosure"])

    def test_pickup_outside_the_window_is_flagged(self):
        arguments = quote_arguments(self.clock)
        arguments["departure_window"] = window(self.clock, start_minutes=0, length_minutes=7)
        payload = self.call("quote_ride", arguments)
        for option in payload["options"]:
            late = option["estimated_pickup_at"] > arguments["departure_window"]["latest"]
            self.assertEqual(late, "outside_departure_window" in option["constraint_flags"])
        self.assertTrue(any("outside_departure_window" in o["constraint_flags"] for o in payload["options"]))

    def test_long_pickup_wait_is_advisory(self):
        payload = self.quote(max_pickup_wait_minutes=8)
        slow = [o for o in payload["options"] if "long_pickup_wait" in o["constraint_flags"]]
        self.assertTrue(slow)
        self.assertTrue(all(o["estimated_pickup_wait_minutes"] > 8 for o in slow))

    def test_coordinates_work_without_addresses(self):
        arguments = quote_arguments(self.clock)
        arguments["origin"], arguments["destination"] = OFFICE_POINT, BARBER_POINT
        self.assertTrue(self.call("quote_ride", arguments)["options"])

    def test_a_window_that_ends_before_it_starts_is_refused(self):
        arguments = quote_arguments(self.clock)
        arguments["departure_window"] = {"earliest": "2026-10-12T15:00:00-07:00", "latest": "2026-10-12T14:00:00-07:00"}
        payload = self.call("quote_ride", arguments, expect_error=True)
        self.assertEqual("invalid_argument", payload["error"]["code"])
        self.assertEqual("/departure_window/latest", payload["error"]["field"])

    def test_a_window_already_over_is_refused(self):
        arguments = quote_arguments(self.clock)
        arguments["departure_window"] = window(self.clock, start_minutes=-60, length_minutes=10)
        self.assertEqual("invalid_argument", self.error_code("quote_ride", arguments))

    def test_missing_budget_is_refused_with_the_field(self):
        arguments = quote_arguments(self.clock)
        del arguments["budget_ceiling"]
        payload = self.call("quote_ride", arguments, expect_error=True)
        self.assertEqual("/budget_ceiling", payload["error"]["field"])

    def test_versions(self):
        for version, ok in (("1", True), ("1.0.0", True), ("1.9.3", True), ("2", False), ("0.9.0", False)):
            arguments = dict(quote_arguments(self.clock), contract_version=version)
            is_error, payload = self.connector.call("quote_ride", arguments)
            self.assertEqual(not ok, is_error, version)
            if not ok:
                self.assertEqual("unsupported_contract_version", payload["error"]["code"])

    def test_a_currency_no_backend_serves_means_no_service(self):
        arguments = quote_arguments(self.clock)
        arguments["budget_ceiling"] = {"amount_minor": 5000, "currency": "EUR"}
        self.assertEqual("no_service", self.error_code("quote_ride", arguments))

    def test_unknown_arguments_are_refused_not_ignored(self):
        # inputs are closed: a newer optional argument is sent only to a gateway whose
        # contract_version shows it supports that minor version.
        arguments = dict(quote_arguments(self.clock), passenger_count=2)
        payload = self.call("quote_ride", arguments, expect_error=True)
        self.assertEqual("invalid_argument", payload["error"]["code"])
        self.assertEqual("/passenger_count", payload["error"]["field"])

    def test_unknown_tool(self):
        self.assertEqual("invalid_argument", self.error_code("order_pizza", {}))


class RefusalTests(ConnectorCase, unittest.TestCase):
    def test_one_blocked_service_becomes_a_notice(self):
        self.backends["concierge"].refuse = "blocked"
        payload = self.quote()
        self.assertEqual(["blocked"], [n["code"] for n in payload["notices"]])
        self.assertNotIn("Waymo", {o["provider"] for o in payload["options"]})

    def test_all_blocked_is_an_error_and_says_nothing_was_routed_around(self):
        for backend in self.backends.values():
            backend.refuse = "blocked"
        payload = self.call("quote_ride", quote_arguments(self.clock), expect_error=True)
        self.assertEqual("blocked", payload["error"]["code"])
        self.assertFalse(payload["error"]["retryable"])
        self.assertIn("Nothing was routed around", payload["error"]["message"])

    def test_one_down_service_is_partial_results(self):
        self.backends["partner"].refuse = "down"
        self.assertEqual(["partial_results"], [n["code"] for n in self.quote()["notices"]])

    def test_all_down_is_retryable(self):
        for backend in self.backends.values():
            backend.refuse = "down"
        payload = self.call("quote_ride", quote_arguments(self.clock), expect_error=True)
        self.assertEqual("service_unavailable", payload["error"]["code"])
        self.assertTrue(payload["error"]["retryable"])

    def test_all_rate_limited_carries_retry_after(self):
        for backend in self.backends.values():
            backend.refuse = "rate_limited"
        payload = self.call("quote_ride", quote_arguments(self.clock), expect_error=True)
        self.assertEqual("rate_limited", payload["error"]["code"])
        self.assertEqual(30, payload["error"]["retry_after_seconds"])


class BookTests(ConnectorCase, unittest.TestCase):
    def test_automated_booking_is_confirmed_at_once(self):
        option = self.first(self.quote(), "Lyft")
        payload = self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_0001abcd"})
        booking = payload["booking"]
        self.assertFalse(payload["replayed"])
        self.assertEqual("confirmed", booking["status"])
        self.assertIsNone(booking["confirm_by"])
        self.assertEqual(option["charge_terms"], booking["charge_terms"])
        self.assertEqual(option["cancellation_policy"], booking["cancellation_policy"])
        self.assertEqual("get_ride", booking["tracking"]["status_call"])
        self.assertIsNone(booking["final_charge"])
        self.assertEqual(option["quote_id"], booking["quote_id"])

    def test_booking_twice_returns_the_same_booking(self):
        option = self.first(self.quote(), "Lyft")
        first = self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_0001abcd"})
        self.clock.advance(minutes=30)  # replay works even after the quote has expired.
        second = self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_0001abcd"})
        self.assertTrue(second["replayed"])
        self.assertEqual(first["booking"]["booking_id"], second["booking"]["booking_id"])
        self.assertEqual(1, len(self.backends["partner"].bookings))

    def test_rebooking_with_other_payment_is_a_conflict(self):
        option = self.first(self.quote(), "Lyft")
        self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_0001abcd"})
        self.assertEqual("idempotency_conflict",
                         self.error_code("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_0002abcd"}))
        self.assertEqual("idempotency_conflict", self.error_code("book_ride", {"quote_id": option["quote_id"]}))

    def test_expired_quote(self):
        option = self.first(self.quote(), "Lyft")
        self.clock.advance(minutes=11)
        self.assertEqual("quote_expired", self.error_code("book_ride", {"quote_id": option["quote_id"]}))

    def test_unknown_quote(self):
        self.assertEqual("quote_not_found", self.error_code("book_ride", {"quote_id": "qt_" + "a" * 26}))

    def test_over_budget_option_is_refused(self):
        option = self.first(self.quote(budget=1500), bookable=False)
        self.assertIn("over_budget", option["constraint_flags"])
        self.assertEqual("over_budget", self.error_code("book_ride", {"quote_id": option["quote_id"]}))

    def test_other_unbookable_option_is_refused(self):
        option = self.first(self.quote(accessibility_needs=["car_seat"]), bookable=False)
        self.assertEqual("option_not_bookable", self.error_code("book_ride", {"quote_id": option["quote_id"]}))

    def test_payment_reference_can_be_required(self):
        connector, clock, _ = demo_connector(FakeClock(), require_payment_reference=True)
        self.connector, self.clock = connector, clock
        option = self.first(self.quote(), "Lyft")
        self.assertEqual("payment_required", self.error_code("book_ride", {"quote_id": option["quote_id"]}))
        self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_0001abcd"}, expect_error=False)

    def test_a_card_number_is_never_accepted_as_a_payment_reference(self):
        option = self.first(self.quote(), "Lyft")
        payload = self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "4242424242424242"},
                            expect_error=True)
        self.assertEqual("invalid_argument", payload["error"]["code"])
        self.assertEqual("/payment_reference", payload["error"]["field"])
        self.assertEqual({}, self.backends["partner"].bookings)

    def test_backend_failures_map_to_contract_codes(self):
        for reason, code in (("unavailable", "option_unavailable"), ("price_changed", "price_changed"),
                             ("payment_declined", "payment_declined"), ("down", "service_unavailable")):
            option = self.first(self.quote(), "Lyft")
            self.backends["partner"].fail_next_book = reason
            self.assertEqual(code, self.error_code("book_ride", {"quote_id": option["quote_id"]}), reason)
            # a failed booking does not burn the quote: the same quote_id can be booked on retry.
            self.call("book_ride", {"quote_id": option["quote_id"]}, expect_error=False)


class ConciergeTests(ConnectorCase, unittest.TestCase):
    def book_waymo(self):
        option = self.first(self.quote(preferred_providers=["Waymo"]), "Waymo")
        return self.call("book_ride", {"quote_id": option["quote_id"]})["booking"]

    def test_human_assisted_booking_waits_for_a_person(self):
        booking = self.book_waymo()
        self.assertEqual("requested", booking["status"])
        self.assertEqual("human_assisted", booking["fulfillment"]["method"])
        self.assertIsNotNone(booking["confirm_by"])
        concierge = self.backends["concierge"]
        [request] = concierge.pending()
        self.assertEqual("Waymo", request["provider"])
        self.assertEqual(booking["origin"], request["origin"])
        self.assertEqual(booking["destination"], request["destination"])
        self.assertEqual(booking["confirm_by"], request["confirm_by"])
        concierge.confirm(request["reference"])
        later = self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]
        self.assertEqual("confirmed", later["status"])
        self.assertIsNone(later["confirm_by"])
        self.assertEqual("White electric vehicle, no driver", later["tracking"]["vehicle_description"])

    def test_human_assisted_options_are_off_unless_enabled(self):
        connector, clock, backends = demo_connector(FakeClock(), allow_human_assisted=False)
        is_error, payload = connector.call("quote_ride", quote_arguments(clock, preferred_providers=["Waymo"]))
        self.assertFalse(is_error)
        self.assertNotIn("Waymo", {o["provider"] for o in payload["options"]})
        self.assertTrue(all(o["fulfillment"]["method"] == "automated" for o in payload["options"]))

    def test_disclosure_wording_is_configurable(self):
        connector, clock, _ = demo_connector(FakeClock(), concierge_disclosure="Approved wording.")
        _, payload = connector.call("quote_ride", quote_arguments(clock))
        waymo = [o for o in payload["options"] if o["provider"] == "Waymo"][0]
        self.assertEqual("Approved wording.", waymo["fulfillment"]["disclosure"])

    def test_unconfirmed_booking_fails_at_the_deadline_and_charges_nothing(self):
        booking = self.book_waymo()
        self.clock.advance(minutes=16)
        later = self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]
        self.assertEqual("failed", later["status"])
        self.assertEqual(0, later["final_charge"]["total"]["amount_minor"])
        self.assertEqual(later["charge_terms"]["authorization_cap"], later["final_charge"]["amount_to_release"])

    def test_declined_booking_fails(self):
        booking = self.book_waymo()
        concierge = self.backends["concierge"]
        concierge.decline(concierge.pending()[0]["reference"])
        self.assertEqual("failed", self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]["status"])


class TrackingTests(ConnectorCase, unittest.TestCase):
    def test_status_moves_through_the_trip_and_settles_within_the_cap(self):
        self.backends["partner"].final_fare_delta_percent = 10
        option = self.first(self.quote(), "Uber")
        booking = self.call("book_ride", {"quote_id": option["quote_id"]})["booking"]
        seen = []
        for _ in range(40):
            status = self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]
            seen.append(status["status"])
            self.clock.advance(minutes=3)
        self.assertEqual(["confirmed", "driver_assigned", "in_progress", "completed"], _distinct(seen))
        charge = status["final_charge"]
        cap = status["charge_terms"]["authorization_cap"]["amount_minor"]
        self.assertLessEqual(charge["total"]["amount_minor"], cap)
        self.assertEqual(cap - charge["total"]["amount_minor"], charge["amount_to_release"]["amount_minor"])
        self.assertEqual(charge["fare"]["amount_minor"] + charge["tip"]["amount_minor"], charge["total"]["amount_minor"])

    def test_a_final_fare_above_the_ceiling_is_clamped(self):
        self.backends["partner"].final_fare_delta_percent = 80
        self.backends["partner"].tip_percent = 90
        option = self.first(self.quote(), "Uber")
        booking = self.call("book_ride", {"quote_id": option["quote_id"]})["booking"]
        self.clock.advance(minutes=120)
        final = self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]
        self.assertEqual(final["charge_terms"]["fare_ceiling"], final["final_charge"]["fare"])
        self.assertEqual(final["charge_terms"]["tip_ceiling"], final["final_charge"]["tip"])
        self.assertEqual(0, final["final_charge"]["amount_to_release"]["amount_minor"])
        self.assertTrue(any(entry["event"].startswith("final charge above ceiling") for entry in self.connector.private_log))

    def test_unknown_booking(self):
        self.assertEqual("booking_not_found", self.error_code("get_ride", {"booking_id": "bk_" + "a" * 26}))
        self.assertEqual("booking_not_found", self.error_code("cancel_ride", {"booking_id": "bk_" + "a" * 26}))


class CancelTests(ConnectorCase, unittest.TestCase):
    def book(self, start_minutes=0):
        arguments = quote_arguments(self.clock)
        arguments["departure_window"] = window(self.clock, start_minutes=start_minutes)
        option = self.first(self.call("quote_ride", arguments), "Lyft")
        return self.call("book_ride", {"quote_id": option["quote_id"]})["booking"]

    def test_free_cancellation_releases_everything(self):
        booking = self.book()
        payload = self.call("cancel_ride", {"booking_id": booking["booking_id"], "reason": "plans_changed"})
        self.assertFalse(payload["already_cancelled"])
        charge = payload["booking"]["final_charge"]
        self.assertEqual("cancelled", payload["booking"]["status"])
        self.assertEqual(0, charge["total"]["amount_minor"])
        self.assertEqual(booking["charge_terms"]["authorization_cap"], charge["amount_to_release"])

    def test_late_cancellation_charges_the_published_fee(self):
        booking = self.book()
        self.clock.advance(minutes=3)  # past free_until, before pickup.
        payload = self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        charge = payload["booking"]["final_charge"]
        self.assertEqual(booking["cancellation_policy"]["fee_after_free_period"], charge["cancellation_fee"])
        self.assertEqual(charge["cancellation_fee"], charge["total"])

    def test_scheduled_rides_cancel_free_until_thirty_minutes_before_pickup(self):
        booking = self.book(start_minutes=120)
        self.clock.advance(minutes=60)
        payload = self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        self.assertEqual(0, payload["booking"]["final_charge"]["total"]["amount_minor"])

    def test_cancelling_twice_returns_the_first_result(self):
        booking = self.book()
        first = self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        self.clock.advance(minutes=30)
        second = self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        self.assertTrue(second["already_cancelled"])
        self.assertEqual(first["booking"], second["booking"])

    def test_a_started_trip_cannot_be_cancelled(self):
        booking = self.book()
        self.clock.advance(minutes=15)
        payload = self.call("cancel_ride", {"booking_id": booking["booking_id"]}, expect_error=True)
        self.assertEqual("not_cancellable", payload["error"]["code"])
        self.assertEqual("in_progress", payload["error"]["booking"]["status"])

    def test_a_requested_concierge_booking_can_be_cancelled(self):
        option = self.first(self.quote(), "Waymo")
        booking = self.call("book_ride", {"quote_id": option["quote_id"]})["booking"]
        payload = self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        self.assertEqual("cancelled", payload["booking"]["status"])
        self.assertIsNone(payload["booking"]["confirm_by"])
        self.assertEqual([], self.backends["concierge"].pending())

    def test_get_ride_after_cancel_stays_cancelled(self):
        booking = self.book()
        self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        self.clock.advance(minutes=60)
        self.assertEqual("cancelled", self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]["status"])

    def test_a_backend_that_cannot_cancel_is_reported_honestly(self):
        booking = self.book()

        def refuse(reference, fee):
            raise BackendError("down", "carrier timeout")

        self.backends["partner"].cancel = refuse
        payload = self.call("cancel_ride", {"booking_id": booking["booking_id"]}, expect_error=True)
        self.assertEqual("service_unavailable", payload["error"]["code"])
        self.assertTrue(payload["error"]["retryable"])
        status = self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]["status"]
        self.assertNotEqual("cancelled", status)


class BarberScenarioTests(ConnectorCase, unittest.TestCase):
    """book me a ride to the barber after my 2pm meeting, Waymo preferred, under 25 dollars."""

    def test_the_scenario(self):
        arguments = {
            "contract_version": "1",
            "origin": OFFICE_POINT,
            "destination": dict(BARBER_POINT, label="barber"),
            "departure_window": {"earliest": "2026-10-12T15:00:00-07:00", "latest": "2026-10-12T15:20:00-07:00"},
            "user_preferences": {"preferred_providers": ["Waymo"]},
            "budget_ceiling": usd(2500),
        }
        quote = self.call("quote_ride", arguments)
        best = quote["options"][0]
        self.assertEqual("Waymo", best["provider"])
        self.assertTrue(best["bookable"])
        self.assertLessEqual(best["charge_terms"]["authorization_cap"]["amount_minor"], 2500)
        self.assertGreaterEqual(best["estimated_pickup_at"], "2026-10-12T15:00:00-07:00")
        booking = self.call("book_ride", {"quote_id": best["quote_id"], "payment_reference": "hold_barber01"})["booking"]
        concierge = self.backends["concierge"]
        concierge.confirm(concierge.pending()[0]["reference"])
        self.assertEqual("confirmed", self.call("get_ride", {"booking_id": booking["booking_id"]})["booking"]["status"])


def _distinct(values):
    out = []
    for value in values:
        if not out or out[-1] != value:
            out.append(value)
    return out


if __name__ == "__main__":
    unittest.main()
