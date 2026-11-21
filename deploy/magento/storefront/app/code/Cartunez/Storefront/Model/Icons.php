<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Model;

/**
 * Small inline SVG line icons for the storefront (templates, blocks and the CMS
 * content written by the data patches). Fixed markup only: nothing from the
 * request or the database goes into these strings. Icons follow currentColor.
 */
class Icons
{
    private const PATHS = [
        'arrow' => '<path d="M5 12h14M13 6l6 6-6 6"/>',
        'bag' => '<path d="M6 7h12l1 14H5L6 7z"/><path d="M9 7a3 3 0 0 1 6 0"/>',
        'calendar' => '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/>',
        'camera' => '<rect x="2" y="6" width="14" height="12" rx="2"/><path d="M16 10.5l6-3.5v10l-6-3.5"/>',
        'car' => '<path d="M5 17v-5l2.2-5.2A2 2 0 0 1 9 5.5h6a2 2 0 0 1 1.8 1.3L19 12v5"/><path d="M3 17h18v2.5h-3V17M6 17v2.5H3V17M5 12h14"/><path d="M7.5 14.5h.01M16.5 14.5h.01"/>',
        'cash' => '<rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/><path d="M6 12h.01M18 12h.01"/>',
        'chat' => '<path d="M21 11.5a8.5 8.5 0 0 1-12.6 7.4L3 20l1.2-4.8A8.5 8.5 0 1 1 21 11.5z"/>',
        'check' => '<circle cx="12" cy="12" r="9"/><path d="M8 12.3l2.8 2.7L16 9.5"/>',
        'chevron' => '<path d="M6 9l6 6 6-6"/>',
        'clock' => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        'gauge' => '<path d="M4.2 18a9 9 0 1 1 15.6 0"/><path d="M12 14l4-5"/><circle cx="12" cy="14" r="1.6"/>',
        'light' => '<path d="M13 5h1a7 7 0 0 1 0 14h-1z"/><path d="M3 8h6M3 12h6M3 16h6"/>',
        'lock' => '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
        'phone' => '<path d="M5 3h3.5l2 5-2.4 1.6a11 11 0 0 0 6.3 6.3L16 13.5l5 2V19a2 2 0 0 1-2 2A16 16 0 0 1 3 5a2 2 0 0 1 2-2z"/>',
        'pin' => '<path d="M12 21s-7-6.1-7-11.5a7 7 0 0 1 14 0C19 14.9 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>',
        'plug' => '<path d="M9 2v5M15 2v5M6 7h12v4a6 6 0 0 1-12 0V7zM12 17v5"/>',
        'search' => '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/>',
        'seat' => '<path d="M8 3h4.5a1 1 0 0 1 1 .9L14.5 13H8.4a1 1 0 0 1-1-.9L7 4.1A1 1 0 0 1 8 3z"/><path d="M7.5 13H17a2 2 0 0 1 2 2v2H8M10 17v4M16 17v4"/>',
        'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
        'sparkle' => '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M19 16l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z"/>',
        'speaker' => '<rect x="5" y="2.5" width="14" height="19" rx="2"/><circle cx="12" cy="14" r="4"/><circle cx="12" cy="6.8" r="1.2"/>',
        'sun' => '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
        'truck' => '<path d="M2 6h12v10H2zM14 9.5h4.2L21 13v3h-7"/><circle cx="6.5" cy="17.5" r="2"/><circle cx="17" cy="17.5" r="2"/>',
        'tune' => '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
        'wrench' => '<path d="M14.7 6.3a4 4 0 0 0-5.3 5.2L3 17.9V21h3.1l6.4-6.4a4 4 0 0 0 5.2-5.3l-2.4 2.4-2.6-.5-.5-2.6z"/>',
    ];

    /** WhatsApp mark (filled), 32-unit view box. */
    private const WHATSAPP = '<path fill="currentColor" d="M16 3C8.8 3 3 8.7 3 15.8c0 2.5.7 4.9 2 7L3 29l6.4-2c2 1.1 4.3 1.7 6.6 1.7 7.2 0 13-5.7 13-12.8S23.2 3 16 3zm0 23.4c-2.1 0-4.1-.6-5.8-1.7l-.4-.3-3.8 1.2 1.2-3.7-.3-.4c-1.2-1.8-1.8-3.8-1.8-5.8C5.1 10 10 5.2 16 5.2S26.9 10 26.9 15.8 22 26.4 16 26.4zm6-7.9c-.3-.2-1.9-.9-2.2-1-.3-.1-.5-.2-.7.2l-1 1.2c-.2.2-.4.2-.7.1-.3-.2-1.4-.5-2.6-1.6-1-.9-1.6-1.9-1.8-2.2-.2-.3 0-.5.1-.7l.5-.6c.2-.2.2-.4.3-.6.1-.2 0-.4 0-.6l-1-2.4c-.3-.6-.5-.5-.7-.5h-.6c-.2 0-.6.1-.9.4-.3.3-1.1 1.1-1.1 2.7s1.2 3.1 1.3 3.3c.2.2 2.3 3.5 5.5 4.9 2.7 1.1 3.3.9 3.9.8.6-.1 1.9-.8 2.2-1.5.3-.7.3-1.4.2-1.5-.1-.2-.3-.3-.6-.4z"/>';

    public static function svg(string $name, int $size = 20): string
    {
        $size = max(8, min(64, $size));
        if ($name === 'whatsapp') {
            return '<svg class="cz-ico cz-ico--whatsapp" viewBox="0 0 32 32" width="' . $size . '" height="' . $size
                . '" aria-hidden="true" focusable="false">' . self::WHATSAPP . '</svg>';
        }
        $paths = self::PATHS[$name] ?? self::PATHS['arrow'];
        return '<svg class="cz-ico" viewBox="0 0 24 24" width="' . $size . '" height="' . $size
            . '" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"'
            . ' aria-hidden="true" focusable="false">' . $paths . '</svg>';
    }
}
