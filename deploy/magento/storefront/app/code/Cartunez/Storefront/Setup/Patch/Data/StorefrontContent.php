<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Writes the Cartunez home page and footer block once. Both stay editable in
 * the Magento admin (Content > Pages > Home Page, Content > Blocks > cartunez-footer);
 * this patch never overwrites them again.
 */
class StorefrontContent implements DataPatchInterface
{
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
        if (!$page->getId()) {
            $page->setIdentifier('home')->setStores([0])->setIsActive(1);
        }
        $page->setTitle('Cartunez | Genuine auto parts')
            ->setContentHeading('')
            ->setPageLayout('1column')
            ->setContent($this->homeContent());
        $this->pageResource->save($page);

        $block = $this->blockFactory->create();
        $this->blockResource->load($block, 'cartunez-footer', 'identifier');
        if (!$block->getId()) {
            $block->setIdentifier('cartunez-footer')
                ->setTitle('Cartunez footer')
                ->setIsActive(1)
                ->setStores([0])
                ->setContent($this->footerContent());
            $this->blockResource->save($block);
        }
        return $this;
    }

    private function homeContent(): string
    {
        // Newest parts published from the POS (all categories).
        $conditions = '^[`1`:^[`type`:`Magento||CatalogWidget||Model||Rule||Condition||Combine`,'
            . '`aggregator`:`all`,`value`:`1`,`new_child`:``^]^]';
        $products = '{{widget type="Magento\\CatalogWidget\\Block\\Product\\ProductsList" show_pager="0" '
            . 'products_count="12" template="Magento_CatalogWidget::product/widget/content/grid.phtml" '
            . 'conditions_encoded="' . $conditions . '"}}';

        return <<<HTML
<div class="cz-hero">
  <h1>Genuine auto parts,<br>at honest prices.</h1>
  <p>Filters, brakes, batteries, fluids and more. Checked stock, GST invoice on every order, and fast dispatch from our shop.</p>
  <a class="cz-button" href="#cz-new">Shop the latest parts</a>
  <span class="cz-hero-mark" aria-hidden="true"></span>
</div>
<ul class="cz-benefits">
  <li><strong>Genuine parts</strong><span>Sourced from trusted brands and distributors.</span></li>
  <li><strong>GST invoice</strong><span>Prices include all taxes; invoice with every order.</span></li>
  <li><strong>Live stock</strong><span>What you see is what is on our shelves.</span></li>
  <li><strong>Need help?</strong><span>Tell us your vehicle and we will find the right part.</span></li>
</ul>
<h2 class="cz-section-title" id="cz-new">New in store</h2>
{$products}
HTML;
    }

    private function footerContent(): string
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
      <li>Mon–Sat, 10 am – 8 pm</li>
    </ul>
  </div>
  <div>
    <h4>Orders</h4>
    <ul>
      <li>All prices include GST</li>
      <li>Parts marked "on order" ship in the days shown</li>
      <li>Returns on unused parts with the invoice</li>
    </ul>
  </div>
</div>
HTML;
    }

    public static function getDependencies(): array
    {
        return [];
    }

    public function getAliases(): array
    {
        return [];
    }
}
