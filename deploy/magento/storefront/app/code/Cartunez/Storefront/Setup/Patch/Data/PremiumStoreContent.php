<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Premium home page: studio-style hero, trust strip, category tiles, brands,
 * featured parts, studio services, help and a "visit the studio" panel.
 *
 * Before writing, the current home page and hero are copied into the disabled
 * blocks "cartunez-home-backup" and "cartunez-hero-backup" (Content > Blocks),
 * so nothing typed in the admin is lost. The footer and offer bar, which hold
 * the shop's real details, are not touched.
 *
 * Speed: the first hero photo is a real <img> with fetchpriority="high" and
 * sizes for each screen; the other slides keep their photo in data-* until the
 * page has loaded (scripts.phtml); every other photo is lazy-loaded with its
 * width and height so nothing jumps. Photos are free Unsplash images
 * (unsplash.com/license) until the shop uses its own.
 */
class PremiumStoreContent implements DataPatchInterface
{
    private const PHONE = '+919949695030';
    private const PHONE_TEXT = '099496 95030';
    private const MAP = 'https://www.google.com/maps/search/?api=1&amp;query=Car+Tunez+Veer+Hanuman+Temple+S.P.+Road+Secunderabad+500003';

    // Hero
    private const GARAGE = '1632239524459-5c3137fcdae9';
    private const AMBIENT = '1767277974410-b2c6758537f9';
    private const BOOT_AUDIO = '1726248985986-20bef82d2b52';
    // Services and tiles
    private const DOOR_SPEAKER = '1599836653544-c39c4666e627';
    private const DOOR_LIGHT = '1772555429170-be39986f4d99';
    private const HEADLIGHTS = '1624373784580-f9d3e67991d2';
    private const POLISH = '1780558852670-3f49298ecc1f';
    private const TAIL_NIGHT = '1634215000930-86336716c866';
    private const SUBWOOFERS = '1654619510332-482a15f6c62a';
    private const VENTS = '1773696756753-af4dcfd66eda';
    private const FOAM = '1761312834150-4beefff097a7';
    private const HEADLIGHT_NIGHT = '1615884363252-983eed162938';
    private const CITY_NIGHT = '1610374634235-b51ef357f905';

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource,
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        $page = $this->pageFactory->create();
        $this->pageResource->load($page, 'home', 'identifier');
        $hero = $this->blockFactory->create();
        $this->blockResource->load($hero, 'cartunez-hero', 'identifier');

        if ($page->getId()) {
            $this->saveBlock('cartunez-home-backup', 'Cartunez home page before the premium redesign (backup)', (string)$page->getContent(), false);
        }
        if ($hero->getId()) {
            $this->saveBlock('cartunez-hero-backup', 'Cartunez hero before the premium redesign (backup)', (string)$hero->getContent(), false);
        }
        $this->saveBlock('cartunez-hero', 'Cartunez hero slider', $this->hero(), true);

        if (!$page->getId()) {
            $page->setIdentifier('home')->setStores([0])->setIsActive(1);
        }
        $page->setTitle('Car accessories, audio and styling in Secunderabad')
            ->setMetaDescription('Car accessories, audio installation, interior makeovers, lighting and detailing at Car Tunez, S.P. Road, Secunderabad. Shop online with GST invoice, pickup or delivery across India.')
            ->setContentHeading('')
            ->setPageLayout('1column')
            ->setContent($this->home());
        $this->pageResource->save($page);
        return $this;
    }

    private function saveBlock(string $id, string $title, string $content, bool $active): void
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, $id, 'identifier');
        if (!$block->getId()) {
            $block->setIdentifier($id)->setStores([0]);
        }
        $block->setTitle($title)->setIsActive($active ? 1 : 0)->setContent($content);
        $this->blockResource->save($block);
    }

    private function url(string $photo, int $width, int $height): string
    {
        return 'https://images.unsplash.com/photo-' . $photo
            . '?auto=format&amp;fit=crop&amp;w=' . $width . '&amp;h=' . $height . '&amp;q=62';
    }

    /** srcset for a photo cropped to one aspect ratio at several widths. */
    private function srcset(string $photo, array $widths, float $ratio): string
    {
        $parts = [];
        foreach ($widths as $width) {
            $parts[] = $this->url($photo, $width, (int)round($width / $ratio)) . ' ' . $width . 'w';
        }
        return implode(', ', $parts);
    }

    private function img(string $photo, string $alt, array $widths, float $ratio, string $sizes, int $width): string
    {
        $height = (int)round($width / $ratio);
        return '<img src="' . $this->url($photo, $width, $height) . '" srcset="' . $this->srcset($photo, $widths, $ratio)
            . '" sizes="' . $sizes . '" width="' . $width . '" height="' . $height . '" alt="' . $alt
            . '" loading="lazy" decoding="async">';
    }

    private function search(string $query): string
    {
        return "{{store url='catalogsearch/result'}}?q=" . $query;
    }

    private function hero(): string
    {
        $slides = [
            [self::GARAGE, 'Car Tunez &middot; Secunderabad', 'Get your car rolling in style', 'Accessories, audio, lighting and interiors, chosen and fitted by people who love cars.', $this->search('accessories'), 'Shop accessories'],
            [self::AMBIENT, 'Interior makeovers', 'Step into a better cabin', 'Seat covers, mats, ambient lighting and trims that make every drive feel new.', $this->search('interior'), 'Shop interiors'],
            [self::BOOT_AUDIO, 'Audio installation', 'Hear the drive', 'Speakers, amplifiers, subwoofers and head units, installed and tuned at our studio.', $this->search('speaker'), 'Shop audio'],
        ];
        $sizes = '(max-width: 1280px) 100vw, 1280px';
        $widths = [640, 960, 1280, 1600, 2000];
        $html = '<div class="cz-slider" aria-roledescription="carousel">';
        foreach ($slides as $n => [$photo, $kicker, $title, $text, $link, $cta]) {
            $set = $this->srcset($photo, $widths, 16 / 9);
            $src = $this->url($photo, 1600, 900);
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
                . '<span class="cz-kicker">' . $kicker . '</span>'
                . '<' . $heading . ' class="cz-slide-title">' . $title . '</' . $heading . '>'
                . '<p>' . $text . '</p>'
                . '<div class="cz-slide-actions"><a class="cz-button" href="' . $link . '">' . $cta . '</a>'
                . '<a class="cz-button cz-button--ghost" href="tel:' . self::PHONE . '">Call the studio</a></div>'
                . '</div></div>';
        }
        return $html . '</div>';
    }

    private function home(): string
    {
        $conditions = '^[`1`:^[`type`:`Magento||CatalogWidget||Model||Rule||Condition||Combine`,'
            . '`aggregator`:`all`,`value`:`1`,`new_child`:``^]^]';
        $products = '{{widget type="Magento\\CatalogWidget\\Block\\Product\\ProductsList" show_pager="0" '
            . 'products_count="8" template="Magento_CatalogWidget::product/widget/content/grid.phtml" '
            . 'conditions_encoded="' . $conditions . '"}}';
        $brands = '{{block class="Cartunez\\Storefront\\Block\\BrandCards" template="Cartunez_Storefront::brands.phtml"}}';

        $tileSizes = '(max-width: 767px) 100vw, (max-width: 1280px) 33vw, 420px';
        $tiles = '';
        foreach ([
            [self::SUBWOOFERS, 'Audio &amp; speakers', 'Speakers, amps, subwoofers', 'speaker'],
            [self::VENTS, 'Interior &amp; lighting', 'Ambient light, mats, covers', 'interior'],
            [self::FOAM, 'Car care', 'Shampoo, polish, protection', 'care'],
        ] as [$photo, $title, $text, $query]) {
            $tiles .= '<a class="cz-promo" href="' . $this->search($query) . '">'
                . $this->img($photo, '', [480, 720, 960], 16 / 10, $tileSizes, 720)
                . '<span class="cz-promo-text"><strong>' . $title . '</strong><span>' . $text . '</span>'
                . '<em>Shop now</em></span></a>';
        }

        $serviceSizes = '(max-width: 767px) 100vw, (max-width: 1023px) 50vw, 400px';
        $services = '';
        foreach ([
            [self::DOOR_SPEAKER, 'Audio installation', 'Speakers, amplifiers and head units, wired cleanly and tuned for your car.'],
            [self::DOOR_LIGHT, 'Interior makeovers', 'Seat covers, mats, roof and door trims, ambient lighting.'],
            [self::HEADLIGHTS, 'Lighting upgrades', 'LED and projector headlamps, fog lamps and cabin lights.'],
            [self::TAIL_NIGHT, 'Window film &amp; styling', 'Sun-control film and styling accessories for a sharper look.'],
            [self::POLISH, 'Detailing &amp; protection', 'Polishing, coatings and protection that keep the shine.'],
            [self::HEADLIGHT_NIGHT, 'Performance upgrades', 'Filters, intakes and upgrades chosen for your model.'],
        ] as [$photo, $title, $text]) {
            $services .= '<li><a class="cz-service" href="{{store url=\'contact\'}}">'
                . '<span class="cz-service-photo">' . $this->img($photo, '', [480, 800], 16 / 10, $serviceSizes, 800) . '</span>'
                . '<span class="cz-service-body"><strong>' . $title . '</strong><span>' . $text . '</span></span>'
                . '</a></li>';
        }

        $visitPhoto = $this->img(self::CITY_NIGHT, '', [640, 960, 1280], 4 / 3,
            '(max-width: 1023px) 100vw, 680px', 960);
        $phone = self::PHONE;
        $phoneText = self::PHONE_TEXT;
        $map = self::MAP;

        return <<<HTML
{{block id="cartunez-hero"}}
<ul class="cz-trust">
  <li><strong>Since 2014</strong><span>A Secunderabad favourite for car upgrades</span></li>
  <li><strong>Expert fitting</strong><span>Installed at our S.P. Road studio</span></li>
  <li><strong>GST invoice</strong><span>Prices include all taxes</span></li>
  <li><strong>Pickup or delivery</strong><span>Free pickup, delivery across India</span></li>
</ul>
<div class="cz-section-head">
  <span class="cz-kicker">Shop by category</span>
  <h2>Upgrades for every drive</h2>
</div>
<div class="cz-promos">{$tiles}</div>
{$brands}
<div class="cz-section-head">
  <span class="cz-kicker">In stock now</span>
  <h2 id="cz-new">Featured products</h2>
</div>
{$products}
<section class="cz-studio" aria-labelledby="cz-studio-title">
  <div class="cz-section-head">
    <span class="cz-kicker">At the studio</span>
    <h2 id="cz-studio-title">Fitted by people who know cars</h2>
    <p>Bring your car to our S.P. Road studio. We help you choose, then install it properly, from a single speaker to a complete makeover.</p>
  </div>
  <ul class="cz-services">{$services}</ul>
  <div class="cz-studio-cta">
    <a class="cz-button" href="{{store url='contact'}}">Ask about a fitting</a>
    <a class="cz-button cz-button--ghost" href="tel:{$phone}">Call {$phoneText}</a>
  </div>
</section>
<div class="cz-cta">
  <div>
    <span class="cz-kicker">Not sure what fits?</span>
    <h2>Tell us your car, we will find the right part.</h2>
    <p>Send the make, model and year, or a photo of what you need, and we will reply with options that fit.</p>
  </div>
  <a class="cz-button" href="{{store url='contact'}}">Ask us</a>
</div>
<div class="cz-visit">
  <div class="cz-visit-photo">{$visitPhoto}</div>
  <div class="cz-visit-body">
    <span class="cz-kicker">Visit us</span>
    <h2>Car Tunez studio</h2>
    <dl>
      <dt>Address</dt><dd>Shop No. 12 &amp; 13, Veer Hanuman Temple, S.P. Road, Secunderabad, Hyderabad 500003</dd>
      <dt>Hours</dt><dd>Mon&ndash;Sat 11 am &ndash; 10 pm &middot; Sun 11:30 am &ndash; 6 pm</dd>
      <dt>Phone</dt><dd><a href="tel:{$phone}">{$phoneText}</a></dd>
    </dl>
    <div class="cz-visit-actions">
      <a class="cz-button" href="{$map}" target="_blank" rel="noopener">Get directions</a>
      <a class="cz-button cz-button--ghost" href="tel:{$phone}">Call us</a>
    </div>
  </div>
</div>
HTML;
    }

    public static function getDependencies(): array
    {
        return [ShopDetails::class, BrandSection::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
