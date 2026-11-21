<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Cartunez\Storefront\Model\Icons;
use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * The owner's Google Stitch design: rewrites the home page, the hero slider,
 * the offer bar and the footer, and creates the "Loved by Hyderabad drivers"
 * band (Content > Blocks > cartunez-reviews, with the Google reviews link the
 * owner can change). The home page keeps the live blocks: vehicle finder,
 * department tiles, On sale, Featured (most ordered / newest, with filter
 * chips), brands and New arrivals.
 *
 * Only true claims: since 2014, 12,000+ cars upgraded, authorized dealer for
 * Sony, JBL, Morel, Blaupunkt and DDPAI, open 7 days. Nothing about stock, GST,
 * warranties or star ratings.
 *
 * Safe to run again: each page or block already in the new design (class
 * "cz-stitch") is left alone, and the previous versions are saved once as the
 * disabled blocks *-backup-stitch (Content > Blocks), so nothing typed in the
 * admin is lost. The reviews block is only created when missing.
 */
class StitchStorefront implements DataPatchInterface
{
    public const REVIEWS_BLOCK = 'cartunez-reviews';
    public const GOOGLE_REVIEWS = 'https://www.google.com/maps/search/?api=1&amp;query=Car+Tunez+Veer+Hanuman+Temple+S.P.+Road+Secunderabad';

    private const MARKER = 'cz-stitch';
    private const PHONE = '+919949695030';
    private const PHONE_TEXT = '099496 95030';
    private const WHATSAPP = 'https://wa.me/919949695030';
    private const MAP = 'https://www.google.com/maps/search/?api=1&amp;query=Car+Tunez+Veer+Hanuman+Temple+S.P.+Road+Secunderabad+500003';

    // Unsplash photos already used by the shop (unsplash.com/license).
    private const BOOT_AUDIO = '1726248985986-20bef82d2b52';
    private const AMBIENT = '1767277974410-b2c6758537f9';
    private const HEADLIGHT_NIGHT = '1615884363252-983eed162938';

    private const FINDER = '{{block class="Cartunez\\Storefront\\Block\\VehicleFinder" template="Cartunez_Storefront::finder.phtml" mode="hero"}}';
    private const TILES = '{{block class="Cartunez\\Storefront\\Block\\CategoryTiles" template="Cartunez_Storefront::tiles.phtml"}}';
    private const SALE = '{{block class="Cartunez\\Storefront\\Block\\SaleProducts" template="Cartunez_Storefront::sale.phtml"}}';
    private const FEATURED = '{{block class="Cartunez\\Storefront\\Block\\ProductRow" template="Cartunez_Storefront::featured.phtml" list="best" limit="9" chips="1"}}';
    private const BRANDS = '{{block class="Cartunez\\Storefront\\Block\\BrandCards" template="Cartunez_Storefront::brands.phtml"}}';
    private const NEWEST = '{{block class="Cartunez\\Storefront\\Block\\ProductRow" template="Cartunez_Storefront::row.phtml" list="new" skip_if_best_empty="9"}}';

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource,
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        $this->rewriteBlock('cartunez-hero', 'Cartunez hero slider', $this->hero());
        $this->rewriteBlock('cartunez-announcement', 'Cartunez offer bar', $this->announcement());
        $this->rewriteBlock('cartunez-footer', 'Cartunez footer', $this->footer());

        $reviews = $this->blockFactory->create();
        $this->blockResource->load($reviews, self::REVIEWS_BLOCK, 'identifier');
        if (!$reviews->getId()) {
            $reviews->setIdentifier(self::REVIEWS_BLOCK)
                ->setTitle('Cartunez Google reviews band (change the link to the shop\'s Google Business reviews)')
                ->setStores([0])
                ->setIsActive(1)
                ->setContent($this->reviews());
            $this->blockResource->save($reviews);
        }

        $page = $this->pageFactory->create();
        $this->pageResource->load($page, 'home', 'identifier');
        if ($page->getId() && str_contains((string)$page->getContent(), self::MARKER)) {
            return $this;
        }
        if ($page->getId()) {
            $this->backup('cartunez-home-backup-stitch', 'Cartunez home page before the Stitch design (backup)', (string)$page->getContent());
        } else {
            $page->setIdentifier('home')->setStores([0])->setIsActive(1);
        }
        $page->setTitle('Car audio, lighting & interior upgrades in Secunderabad')
            ->setMetaDescription('Car audio, lighting, interior makeovers, dashcams and styling at Car Tunez, S.P. Road, Secunderabad, since 2014. Expert studio fitting, cash on delivery & UPI, pickup or delivery across India.')
            ->setContentHeading('')
            ->setPageLayout('1column')
            ->setContent($this->home());
        $this->pageResource->save($page);
        return $this;
    }

    /** Writes the block in the new design, after saving its current content once as a disabled backup. */
    private function rewriteBlock(string $id, string $title, string $content): void
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, $id, 'identifier');
        if ($block->getId()) {
            if (str_contains((string)$block->getContent(), self::MARKER)) {
                return;
            }
            $this->backup($id . '-backup-stitch', $title . ' before the Stitch design (backup)', (string)$block->getContent());
        } else {
            $block->setIdentifier($id)->setStores([0]);
        }
        $block->setTitle($title)->setIsActive(1)->setContent($content);
        $this->blockResource->save($block);
    }

    private function backup(string $id, string $title, string $content): void
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, $id, 'identifier');
        if ($block->getId()) {
            return; // the first backup is the one worth keeping
        }
        $block->setIdentifier($id)->setStores([0])->setTitle($title)->setIsActive(0)->setContent($content);
        $this->blockResource->save($block);
    }

    private function url(string $photo, int $width, int $height): string
    {
        return 'https://images.unsplash.com/photo-' . $photo
            . '?auto=format&amp;fit=crop&amp;w=' . $width . '&amp;h=' . $height . '&amp;q=62';
    }

    private function srcset(string $photo): string
    {
        $parts = [];
        foreach ([640, 960, 1280, 1600, 2000] as $width) {
            $parts[] = $this->url($photo, $width, (int)round($width * 9 / 16)) . ' ' . $width . 'w';
        }
        return implode(', ', $parts);
    }

    private function search(string $word): string
    {
        return "{{store url='catalogsearch/result'}}?q=" . $word;
    }

    private function wa(string $text): string
    {
        return self::WHATSAPP . '?text=' . rawurlencode($text);
    }

    private function hero(): string
    {
        $slides = [
            [self::BOOT_AUDIO, 'Car Tunez Hyderabad &middot; Studio fitted', 'Hear the drive.', 'Feel the road.',
                'Speakers, amplifiers, subwoofers and touchscreen head units, fitted and tuned at our Secunderabad studio. Plug-and-play couplers, no spliced wires.',
                $this->search('speaker'), 'Explore audio gear'],
            [self::AMBIENT, 'Interior makeovers', 'Step into a', 'better cabin.',
                'Seat covers, mats, ambient lighting and trims that make every drive feel new, fitted at our studio.',
                $this->search('interior'), 'Shop interiors'],
            [self::HEADLIGHT_NIGHT, 'Lighting upgrades', 'See further.', 'Arrive in style.',
                'LED and projector headlamps, fog lamps and DRLs, chosen for your car and fitted at the studio.',
                $this->search('light'), 'Shop lighting'],
        ];
        $sizes = '(max-width: 1280px) 100vw, 1200px';
        $arrow = Icons::svg('arrow', 18);
        $phone = Icons::svg('phone', 18);
        $html = '<div class="cz-slider ' . self::MARKER . '" aria-roledescription="carousel" aria-label="Car Tunez studio">'
            . '<div class="cz-hero-badges"><span class="cz-pill cz-pill--red"><span class="cz-pulse" aria-hidden="true"></span>Secunderabad studio fitted</span>'
            . '<span class="cz-hero-est">Est. 2014 &middot; S.P. Road studio</span></div>';
        foreach ($slides as $n => [$photo, $kicker, $line1, $line2, $text, $link, $cta]) {
            $src = $this->url($photo, 1600, 900);
            $set = $this->srcset($photo);
            // First photo: found by the browser at once. Others: loaded after the page (scripts.phtml).
            $image = $n === 0
                ? '<img class="cz-slide-img" src="' . $src . '" srcset="' . $set . '" sizes="' . $sizes
                    . '" width="1600" height="900" alt="" fetchpriority="high" decoding="async">'
                : '<img class="cz-slide-img" data-src="' . $src . '" data-srcset="' . $set . '" data-sizes="' . $sizes
                    . '" width="1600" height="900" alt="" decoding="async">';
            $heading = $n === 0 ? 'h1' : 'h2';
            $html .= '<div class="cz-slide" role="group" aria-label="' . ($n + 1) . ' of ' . count($slides) . '">'
                . $image
                . '<div class="cz-slide-content">'
                . '<p class="cz-slide-kicker">' . $kicker . '</p>'
                . '<' . $heading . ' class="cz-slide-title">' . $line1 . '<br><span class="cz-grad">' . $line2 . '</span></' . $heading . '>'
                . '<p class="cz-slide-text">' . $text . '</p>'
                . '<div class="cz-slide-actions"><a class="cz-button cz-button--bloom" href="' . $link . '">' . $cta . $arrow . '</a>'
                . '<a class="cz-button cz-button--dark" href="tel:' . self::PHONE . '">' . $phone . 'Call the studio</a></div>'
                . '</div></div>';
        }
        return $html . '<p class="cz-hero-note">' . Icons::svg('check', 18)
            . '<span>Open 7 days at Veer Hanuman Temple, S.P. Road</span></p></div>';
    }

    private function announcement(): string
    {
        return '<div class="cz-announcement ' . self::MARKER . '"><div class="cz-ann-inner">'
            . '<p class="cz-ann-points"><span>Free delivery above &#8377;1,999</span>'
            . '<span class="cz-ann-extra">Cash on delivery &amp; UPI</span>'
            . '<span class="cz-ann-extra">Expert studio fitting at S.P. Road, Secunderabad</span></p>'
            . '<p class="cz-ann-contact"><a href="tel:' . self::PHONE . '">Call ' . self::PHONE_TEXT . '</a>'
            . '<span class="cz-ann-hours">Today <span data-cz-hours="today">11 AM &ndash; 10 PM</span></span></p>'
            . '</div></div>';
    }

    private function reviews(): string
    {
        $link = self::GOOGLE_REVIEWS;
        $chat = Icons::svg('chat', 28);
        $arrow = Icons::svg('arrow', 18);
        return <<<HTML
<section class="cz-reviews" aria-labelledby="cz-reviews-title">
  <span class="cz-reviews-icon">{$chat}</span>
  <span class="cz-kicker cz-kicker--red">Driver feedback</span>
  <h2 id="cz-reviews-title">Loved by Hyderabad drivers</h2>
  <p>12,000+ cars upgraded at our S.P. Road studio since 2014. Read what customers say about their fitting on Google, and leave a review after yours.</p>
  <a class="cz-button cz-button--light" href="{$link}" target="_blank" rel="noopener">See our Google reviews{$arrow}</a>
</section>
HTML;
    }

    private function footer(): string
    {
        $map = self::MAP;
        $phone = self::PHONE;
        $phoneText = self::PHONE_TEXT;
        $wa = $this->wa('Hi Car Tunez, I have a question');
        $shield = Icons::svg('shield', 16);
        $lock = Icons::svg('lock', 16);
        $cash = Icons::svg('cash', 16);
        $check = Icons::svg('check', 16);
        $marker = self::MARKER;
        return <<<HTML
<div class="cz-footer {$marker}">
  <div class="cz-footer-brand">
    <p class="cz-footer-logo"><img src="{{view url='images/logo-dark.png'}}" alt="" width="56" height="48" loading="lazy"><span>Car Tunez</span></p>
    <p>Shop No. 12 &amp; 13, Veer Hanuman Temple,<br>S.P. Road, Secunderabad,<br>Hyderabad, Telangana 500003</p>
    <p class="cz-footer-est">Est. 2014 &middot; Car audio, lighting, interiors and styling, fitted at our studio.</p>
    <p><a href="{$map}" target="_blank" rel="noopener">Get directions</a></p>
  </div>
  <div>
    <h4>Studio &amp; support</h4>
    <ul>
      <li>Mon&ndash;Sat: 11 AM &ndash; 10 PM</li>
      <li>Sunday: 11:30 AM &ndash; 6 PM</li>
      <li>Hotline: <a href="tel:{$phone}">{$phoneText}</a></li>
      <li><a href="{$wa}" target="_blank" rel="noopener">WhatsApp us</a></li>
    </ul>
  </div>
  <div>
    <h4>Quick links</h4>
    <ul>
      <li><a href="{{store url=''}}#cz-finder">Vehicle compatibility guide</a></li>
      <li><a href="{{store direct_url='shipping-policy'}}">Shipping &amp; delivery</a></li>
      <li><a href="{{store direct_url='returns-and-refunds'}}">Returns &amp; refunds</a></li>
      <li><a href="{{store direct_url='terms-and-conditions'}}">Terms &amp; conditions</a></li>
      <li><a href="{{store direct_url='privacy-policy-cookie-restriction-mode'}}">Privacy policy</a></li>
      <li><a href="{{store direct_url='contact'}}">Studio booking &amp; contact</a></li>
    </ul>
  </div>
  <div>
    <h4>Shop with confidence</h4>
    <ul class="cz-footer-trust">
      <li>{$shield}<span>Genuine accessories</span></li>
      <li>{$lock}<span>Secure checkout</span></li>
      <li>{$cash}<span>Cash on delivery &amp; UPI</span></li>
      <li>{$check}<span>Authorized dealer: Sony, JBL, Morel, Blaupunkt &amp; DDPAI</span></li>
    </ul>
  </div>
</div>
HTML;
    }

    private function home(): string
    {
        $i = static fn (string $name, int $size = 22): string => Icons::svg($name, $size);
        $map = self::MAP;
        $phone = self::PHONE;
        $phoneText = self::PHONE_TEXT;
        $book = $this->wa('Hi Car Tunez, I would like to book a fitting slot at the studio.');
        $quote = $this->wa('Hi Car Tunez, I would like a quote. My car: ');
        $marker = self::MARKER;
        $finder = self::FINDER;
        $tiles = self::TILES;
        $sale = self::SALE;
        $featured = self::FEATURED;
        $brands = self::BRANDS;
        $newest = self::NEWEST;
        $icoCal = $i('calendar');
        $icoPlug = $i('plug');
        $icoTruck = $i('truck');
        $icoShield = $i('shield');
        $icoTune = $i('tune', 20);
        $icoSpark = $i('sparkle', 20);
        $icoPlug20 = $i('plug', 20);
        $icoPin = $i('pin', 18);
        $icoPinBig = $i('pin', 30);
        $icoCalBtn = $i('calendar', 18);
        $icoCheck = $i('check', 18);
        $icoWa = Icons::svg('whatsapp', 22);
        $icoPhone = $i('phone', 20);

        return <<<HTML
<div class="cz-home {$marker}">
{{block id="cartunez-hero"}}
<ul class="cz-trust">
  <li><span class="cz-trust-icon cz-tone-cyan">{$icoCal}</span><span><strong>Since 2014</strong><span>12,000+ cars upgraded in Hyderabad</span></span></li>
  <li><span class="cz-trust-icon cz-tone-green">{$icoPlug}</span><span><strong>Zero wire splicing</strong><span>Plug-and-play couplers, coupler-to-coupler fit</span></span></li>
  <li><span class="cz-trust-icon cz-tone-red">{$icoTruck}</span><span><strong>Free delivery / pickup</strong><span>Free delivery above &#8377;1,999 or S.P. Rd pickup</span></span></li>
  <li><span class="cz-trust-icon cz-tone-blue">{$icoShield}</span><span><strong>Authorized dealer</strong><span>Sony, JBL, Morel, Blaupunkt &amp; DDPAI</span></span></li>
</ul>
{$finder}
{$tiles}
{$sale}
{$featured}
<section class="cz-brands-wrap">
{$brands}
</section>
{$newest}
<section class="cz-studio" aria-labelledby="cz-studio-title">
  <div class="cz-studio-inner">
    <div class="cz-studio-copy">
      <span class="cz-kicker">S.P. Road studio</span>
      <h2 id="cz-studio-title">Fitted by people who live &amp; breathe cars</h2>
      <p>Since 2014, Car Tunez at S.P. Road has been where Hyderabad drivers bring their cars for audio, lighting and interior upgrades. No rushed jobs, no cut wiring.</p>
      <ul class="cz-features">
        <li><span class="cz-feature-icon cz-tone-green">{$icoPlug20}</span><span><strong>Coupler-to-coupler wiring</strong><span>Plug-and-play harnesses: no cutting or splicing of your car's wiring.</span></span></li>
        <li><span class="cz-feature-icon cz-tone-cyan">{$icoTune}</span><span><strong>Set up and tuned in your car</strong><span>Speakers, amplifiers and head units are tested and tuned before you drive out.</span></span></li>
        <li><span class="cz-feature-icon cz-tone-red">{$icoSpark}</span><span><strong>Clean, careful installs</strong><span>Trims refitted neatly, damping where it helps, cables routed and tidied.</span></span></li>
      </ul>
      <div class="cz-studio-actions">
        <a class="cz-button cz-button--dark" href="{$map}" target="_blank" rel="noopener">{$icoPin}Open Google Maps</a>
        <a class="cz-button" href="{$book}" target="_blank" rel="noopener">{$icoCalBtn}Book a fitting slot</a>
      </div>
    </div>
    <div class="cz-location" data-cz-status>
      <div class="cz-location-head">
        <div>
          <span class="cz-label">Studio location</span>
          <strong>Shop 12 &amp; 13, Veer Hanuman Temple, S.P. Road</strong>
        </div>
        <p class="cz-location-status"><span class="cz-dot" aria-hidden="true"></span><span data-cz-status-label data-open="Studio open today" data-closed="Studio closed now">Studio hours</span><span data-cz-status-next>Mon&ndash;Sat 11 AM &ndash; 10 PM</span></p>
      </div>
      <a class="cz-map" href="{$map}" target="_blank" rel="noopener">
        <span class="cz-map-pin">{$icoPinBig}</span>
        <span class="cz-map-addr">{$icoPin}S.P. Road, Secunderabad, Telangana 500003</span>
        <span class="cz-map-open">Open in Google Maps</span>
      </a>
      <ul class="cz-stats">
        <li><strong>10+ years</strong><span>Serving Hyderabad</span></li>
        <li><strong>12,000+</strong><span>Cars upgraded</span></li>
        <li><strong>7 days</strong><span>Open a week</span></li>
      </ul>
      <p class="cz-hours-line">Mon&ndash;Sat 11 AM &ndash; 10 PM &middot; Sun 11:30 AM &ndash; 6 PM</p>
    </div>
  </div>
</section>
{{block id="cartunez-reviews"}}
<section class="cz-cta" aria-labelledby="cz-cta-title">
  <div class="cz-cta-copy">
    <span class="cz-kicker cz-kicker--red">Ready to upgrade?</span>
    <h2 id="cz-cta-title">Upgrade your car this weekend</h2>
    <p>Send your car model, budget or the upgrade you have in mind. We reply on WhatsApp with parts that fit, prices and a fitting slot.</p>
    <ul class="cz-cta-points">
      <li>{$icoCheck}Instant WhatsApp quote</li>
      <li>{$icoCheck}Pickup or delivery</li>
      <li>{$icoCheck}Expert studio fitting</li>
    </ul>
  </div>
  <div class="cz-cta-actions">
    <a class="cz-button cz-button--wa cz-button--lg" href="{$quote}" target="_blank" rel="noopener">{$icoWa}WhatsApp {$phoneText}</a>
    <a class="cz-button cz-button--ghost cz-button--lg" href="tel:{$phone}">{$icoPhone}Call studio</a>
  </div>
</section>
</div>
HTML;
    }

    public static function getDependencies(): array
    {
        return [HomeFinderAndRows::class, RemoveGst::class, AlwaysOrderable::class, StitchMenu::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
