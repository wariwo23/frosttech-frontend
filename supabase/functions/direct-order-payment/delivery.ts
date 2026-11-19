import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// Product categories permitted for automatic delivery.
export const DELIVERY_ELIGIBLE_CATEGORIES = [
  "Air Conditioners",
  "Refrigeration Parts",
  "HVAC Accessories",
];

// Order statuses permitted when creating a delivery record.
export const DELIVERY_CREATION_STATUSES = [
  "paid",
  "processing",
  "ready_for_delivery",
];

// Order statuses recognised by the payment verification function.
export const ALLOWED_ORDER_STATUSES = [
  "paid",
  "processing",
  "ready_for_delivery",
  "out_for_delivery",
  "delivered",
  "completed",
];

export interface DeliveryOrder {
  id: string;
  status: string;
  delivery_fee: number | string | null;
  delivery_address: string | null;
}

export interface DeliveryResult {
  deliveryCreated: boolean;
  existingDelivery: boolean;
  deliveryId: string | null;
  deliveryStatus: string | null;
  needsAdminReview: boolean;
  reviewReasons: string[];
}

function isValidAmount(value: unknown): boolean {
  return (
    value !== null &&
    value !== undefined &&
    value !== "" &&
    Number.isFinite(Number(value)) &&
    Number(value) >= 0
  );
}

export async function processDelivery(
  db: SupabaseClient,
  order: DeliveryOrder,
  productCategory: string | null,
  ownershipVerified: boolean,
  needsAdminReviewBeforeDelivery: boolean,
): Promise<DeliveryResult> {

  const result: DeliveryResult = {
    deliveryCreated: false,
    existingDelivery: false,
    deliveryId: null,
    deliveryStatus: null,
    needsAdminReview: needsAdminReviewBeforeDelivery,
    reviewReasons: [],
  };

  // 1. Confirm that payment and order ownership are verified.

  if (!ownershipVerified) {
    result.needsAdminReview = true;

    result.reviewReasons.push(
      "Order ownership could not be verified.",
    );

    return result;
  }

  // 2. Check whether a delivery record already exists.

  const {
    data: existing,
    error: lookupError,
  } = await db
    .from("deliveries")
    .select("id,status")
    .eq("order_id", order.id)
    .maybeSingle();

  if (lookupError) {
    console.error(
      "Delivery lookup failed:",
      lookupError.message,
    );

    result.needsAdminReview = true;

    result.reviewReasons.push(
      "The existing delivery record could not be checked.",
    );

    return result;
  }

  // Never create another delivery for an order that already has one.

  if (existing) {
    result.existingDelivery = true;
    result.deliveryId = existing.id;
    result.deliveryStatus = existing.status;

    return result;
  }

  // 3. Confirm that the product category is eligible.

  const productEligible =
    !!productCategory &&
    DELIVERY_ELIGIBLE_CATEGORIES.includes(productCategory);

  if (!productEligible) {
    if (!needsAdminReviewBeforeDelivery) {
      result.reviewReasons.push(
        "The product category is not eligible for automatic delivery.",
      );
    }

    return result;
  }

  // 4. Stop automatic delivery when administrator review is required.

  if (needsAdminReviewBeforeDelivery) {
    result.needsAdminReview = true;

    result.reviewReasons.push(
      "The order requires administrator review before delivery creation.",
    );

    return result;
  }

  // 5. Confirm that the order status permits delivery creation.

  if (!DELIVERY_CREATION_STATUSES.includes(order.status)) {
    result.needsAdminReview = true;

    result.reviewReasons.push(
      `The order status "${order.status}" is not an automatic delivery-creation status.`,
    );

    return result;
  }

  // 6. Validate the delivery fee.

  if (!isValidAmount(order.delivery_fee)) {
    result.needsAdminReview = true;

    result.reviewReasons.push(
      "The order delivery fee is invalid.",
    );

    return result;
  }

  // 7. Confirm that the delivery address is available.

  if (
    !order.delivery_address ||
    !order.delivery_address.trim()
  ) {
    result.needsAdminReview = true;

    result.reviewReasons.push(
      "The delivery address is missing. Administrator review is required.",
    );

    return result;
  }

  // 8. Create the delivery record.

  const {
    data: newDelivery,
    error: insertError,
  } = await db
    .from("deliveries")
    .insert({
      order_id: order.id,
      delivery_fee: Number(order.delivery_fee),
      delivery_address: order.delivery_address.trim(),
      status: "pending",
    })
    .select("id,status")
    .maybeSingle();

  // 9. Handle a duplicate delivery attempt safely.

  if (insertError) {
    if (insertError.code === "23505") {
      const {
        data: concurrentDelivery,
        error: concurrentError,
      } = await db
        .from("deliveries")
        .select("id,status")
        .eq("order_id", order.id)
        .maybeSingle();

      if (!concurrentError && concurrentDelivery) {
        result.existingDelivery = true;
        result.deliveryId = concurrentDelivery.id;
        result.deliveryStatus = concurrentDelivery.status;
      } else {
        result.needsAdminReview = true;

        result.reviewReasons.push(
          "A duplicate delivery conflict occurred and the existing delivery could not be confirmed.",
        );
      }

      return result;
    }

    console.error(
      "Delivery creation failed:",
      insertError.message,
    );

    result.needsAdminReview = true;

    result.reviewReasons.push(
      "Payment was saved, but the delivery record could not be created.",
    );

    return result;
  }

  // 10. Confirm that the database returned the new delivery.

  if (!newDelivery) {
    result.needsAdminReview = true;

    result.reviewReasons.push(
      "The delivery insert returned no confirmed delivery record.",
    );

    return result;
  }

  // 11. Return the confirmed delivery details.

  result.deliveryCreated = true;
  result.deliveryId = newDelivery.id;
  result.deliveryStatus = newDelivery.status;

  return result;
}