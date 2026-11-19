<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Dark storefront: offer bar, hero slider, promo tiles, featured parts and
 * benefits. Written once; everything stays editable in the admin:
 *   Content > Pages > Home Page
 *   Content > Blocks > cartunez-hero, cartunez-announcement, cartunez-footer
 * Photos are free Unsplash images (unsplash.com/license) until the shop has its own.
 */
class DarkStoreContent implements DataPatchInterface
{
    private const IMG = 'https://images.unsplash.com/photo-%s?auto=format&fit=crop&w=%d&q=70';
    private const ENGINE = '1519752594763-2633d8d4ea29';
    private const BRAKE = '1760317890322-364a810cd4da';
    private const HUB = '1656232976683-7b688560e427';

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource,
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        $this->saveBlock('cartunez-announcement', 'Cartunez offer bar', $this->announcement(), true);
        $this->saveBlock('cartunez-hero', 'Cartunez hero slider', $this->hero(), true);
        $this->saveBlock('cartunez-footer', 'Cartunez footer', $this->footer(), true);

        $page = $this->pageFactory->create();
        $this->pageResource->load($page, 'home', 'identifier');
        if (!$page->getId()) {
            $page->setIdentifier('home')->setStores([0])->setIsActive(1);
        }
        $page->setTitle('Cartunez | Genuine auto parts')
            ->setContentHeading('')
            ->setPageLayout('1column')
            ->setContent($this->home());
        $this->pageResource->save($page);
        return $this;
    }

    private function saveBlock(string $id, string $title, string $content, bool $overwrite): void
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, $id, 'identifier');
        if ($block->getId() && !$overwrite) {
            return;
        }
        if (!$block->getId()) {
            $block->setIdentifier($id)->setStores([0]);
        }
        $block->setTitle($title)->setIsActive(1)->setContent($content);
        $this->blockResource->save($block);
    }

    private function img(string $photo, int $width): string
    {
        return sprintf(self::IMG, $photo, $width);
    }

    private function announcement(): string
    {
        return '<div class="cz-announcement">Genuine parts &middot; GST invoice on every order &middot; '
            . 'Free help finding the right part for your vehicle</div>';
    }

    private function hero(): string
    {
        $slides = [
            [self::ENGINE, 'Engine &amp; service', 'Keep it running strong', 'Filters, plugs, belts and fluids for regular service, in stock and ready to ship.', 'engine'],
            [self::BRAKE, 'Brakes', 'Stop with confidence', 'Pads, discs and brake fluid from trusted brands, checked before dispatch.', 'brake'],
            [self::HUB, 'Wheels &amp; suspension', 'Built for Indian roads', 'Bearings, hubs and suspension parts for everyday cars and SUVs.', 'wheel'],
        ];
        $html = '<div class="cz-slider">';
        foreach ($slides as [$photo, $kicker, $title, $text, $query]) {
            $html .= '<div class="cz-slide" style="background-image:url(\'' . $this->img($photo, 1920) . '\')">'
                . '<div class="cz-slide-content">'
                . '<span class="cz-kicker">' . $kicker . '</span>'
                . '<h2>' . $title . '</h2>'
                . '<p>' . $text . '</p>'
                . '<a class="cz-button" href="{{store url=\'catalogsearch/result\'}}?q=' . $query . '">Shop now</a>'
                . '</div></div>';
        }
        return $html . '</div>';
    }

    private function home(): string
    {
        $conditions = '^[`1`:^[`type`:`Magento||CatalogWidget||Model||Rule||Condition||Combine`,'
            . '`aggregator`:`all`,`value`:`1`,`new_child`:``^]^]';
        $products = '{{widget type="Magento\\CatalogWidget\\Block\\Product\\ProductsList" show_pager="0" '
            . 'products_count="12" template="Magento_CatalogWidget::product/widget/content/grid.phtml" '
            . 'conditions_encoded="' . $conditions . '"}}';
        $tiles = '';
        foreach ([
            [self::BRAKE, 'Brake parts', 'Pads, discs, fluid', 'brake'],
            [self::ENGINE, 'Engine care', 'Filters, oil, plugs', 'filter'],
            [self::HUB, 'Wheels &amp; hubs', 'Bearings, hubs, more', 'wheel'],
        ] as [$photo, $title, $text, $query]) {
            $tiles .= '<a class="cz-promo" href="{{store url=\'catalogsearch/result\'}}?q=' . $query . '" '
                . 'style="background-image:url(\'' . $this->img($photo, 900) . '\')">'
                . '<span class="cz-promo-text"><strong>' . $title . '</strong><span>' . $text . '</span>'
                . '<em>Shop now</em></span></a>';
        }

        return <<<HTML
{{block id="cartunez-hero"}}
<div class="cz-promos">{$tiles}</div>
<div class="cz-section-head">
  <span class="cz-kicker">In stock now</span>
  <h2 id="cz-new">Featured parts</h2>
</div>
{$products}
<div class="cz-cta">
  <div>
    <span class="cz-kicker">Not sure what fits?</span>
    <h2>Tell us your vehicle, we will find the part.</h2>
    <p>Send your car's make, model and year, or a photo of the old part, and we will reply with the right one.</p>
  </div>
  <a class="cz-button" href="{{store url='contact'}}">Ask us</a>
</div>
<ul class="cz-benefits">
  <li><strong>Fast dispatch</strong><span>Parts in stock leave our shop quickly.</span></li>
  <li><strong>GST invoice</strong><span>Prices include all taxes; invoice with every order.</span></li>
  <li><strong>Genuine parts</strong><span>From trusted brands and distributors.</span></li>
  <li><strong>Real help</strong><span>Talk to people who know parts.</span></li>
</ul>
HTML;
    }

    private function footer(): string
    {
        return <<<HTML
<div class="cz-footer">
  <div>
    <h4>Cartunez</h4>
    <p>Genuine auto parts and accessories.</p>
    <p>Shop address, city, PIN</p>
    <p>GSTIN: add your GSTIN here</p>
  </div>
  <div>
    <h4>Help</h4>
    <ul>
      <li>Phone / WhatsApp: add your number</li>
      <li>Email: add your email</li>
      <li>Mon&ndash;Sat, 10 am &ndash; 8 pm</li>
    </ul>
  </div>
  <div>
    <h4>Orders</h4>
    <ul>
      <li>All prices include GST</li>
      <li>Parts marked &ldquo;on order&rdquo; ship in the days shown</li>
      <li>Returns on unused parts with the invoice</li>
    </ul>
  </div>
</div>
HTML;
    }

    public static function getDependencies(): array
    {
        return [StorefrontContent::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
