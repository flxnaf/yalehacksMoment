// OpenClaw skill: register on your gateway so iOS can call POST /tools/invoke with tool "fall_alert".
// Args: contact_name, contact_number, location (lat,lng), optional image_jpeg_base64 (from GuardianAlertManager).

export default async function fallAlert(context) {
  const { contact_name, contact_number, location, image_jpeg_base64 } = context.input;

  if (!contact_number) {
    return { priority: 1, text: "Emergency contact not configured." };
  }

  const locationText = location
    ? `Last known location: https://maps.google.com/?q=${location}`
    : "Location unavailable.";

  const message =
    `🚨 *SightAssist Fall Alert*\n\n` +
    `*${contact_name}* may have fallen and needs assistance.\n\n` +
    `${locationText}\n\n` +
    `_Sent automatically by SightAssist_`;

  await context.channels.whatsapp.send({
    to: contact_number,
    message,
    type: "raw",
  });

  if (image_jpeg_base64 && String(image_jpeg_base64).length > 0) {
    try {
      const buf = Buffer.from(String(image_jpeg_base64), "base64");
      if (buf.length > 0) {
        await context.channels.whatsapp.send({
          to: contact_number,
          message: `📷 Last camera frame — ${contact_name}`,
          media: buf,
          mimeType: "image/jpeg",
          type: "raw",
        });
      }
    } catch {
      /* Location text already sent; gateway may use a different media field — see OpenClaw WhatsApp docs. */
    }
  }

  return {
    priority: 1,
    text: "Emergency contact notified.",
  };
}
