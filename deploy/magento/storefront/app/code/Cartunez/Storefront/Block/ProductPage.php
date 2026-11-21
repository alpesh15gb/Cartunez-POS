<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Block;

use Cartunez\Storefront\Model\ProductCategories;
use Magento\Catalog\Model\Category;
use Magento\Catalog\Model\Product;
use Magento\Catalog\Pricing\Price\FinalPrice;
use Magento\Catalog\Pricing\Price\RegularPrice;
use Magento\Framework\DataObject\IdentityInterface;
use Magento\Framework\Pricing\PriceCurrencyInterface;
use Magento\Framework\Registry;
use Magento\Framework\View\Element\Template;
use Magento\Framework\View\Element\Template\Context;

/**
 * The Cartunez parts of the product page: brand above the title, the price
 * block (selling price, MRP struck through, "You save"), the trust row and the
 * Compatibility / Installation / Delivery and returns tabs. One class, one
 * template per place in the layout. Nothing here mentions stock.
 */
class ProductPage extends Template implements IdentityInterface
{
    public const PHONE = '+919949695030';
    public const PHONE_TEXT = '099496 95030';
    public const WHATSAPP = 'https://wa.me/919949695030';

    public function __construct(
        Context $context,
        private readonly Registry $registry,
        private readonly ProductCategories $productCategories,
        private readonly PriceCurrencyInterface $priceCurrency,
        array $data = []
    ) {
        parent::__construct($context, $data);
    }

    public function getProduct(): ?Product
    {
        $product = $this->registry->registry('product');
        return $product instanceof Product && $product->getId() ? $product : null;
    }

    public function getBrand(): ?Category
    {
        $product = $this->getProduct();
        return $product ? $this->productCategories->forProduct($product)['brand'] : null;
    }

    /**
     * Prices as shown: selling (final) price, MRP (regular price) and the saving.
     * @return array{selling: string, mrp: string, save: string, percent: int, discounted: bool, value: float}
     */
    public function getPrices(): array
    {
        $product = $this->getProduct();
        $selling = $mrp = 0.0;
        if ($product) {
            $info = $product->getPriceInfo();
            $selling = (float)$info->getPrice(FinalPrice::PRICE_CODE)->getAmount()->getValue();
            $mrp = (float)$info->getPrice(RegularPrice::PRICE_CODE)->getAmount()->getValue();
        }
        $discounted = $mrp - $selling >= 0.01;
        $save = $discounted ? $mrp - $selling : 0.0;
        return [
            'selling' => $this->money($selling),
            'mrp' => $this->money($mrp),
            'save' => $this->money($save),
            'percent' => $discounted && $mrp > 0 ? (int)floor($save * 100 / $mrp) : 0,
            'discounted' => $discounted,
            'value' => round($selling, 2),
        ];
    }

    public function getCurrencyCode(): string
    {
        return (string)$this->_storeManager->getStore()->getCurrentCurrencyCode();
    }

    /**
     * Vehicles from cz_fitment (synced by the POS): "V:Make|Model|from|to" lines.
     * @return string[] e.g. "Maruti Suzuki Swift (2018-2025)"
     */
    public function getVehicles(): array
    {
        $vehicles = [];
        foreach ($this->fitmentLines() as $line) {
            if (!str_starts_with($line, 'V:')) {
                continue;
            }
            $parts = explode('|', substr($line, 2));
            if (count($parts) < 4 || trim($parts[0]) === '' || trim($parts[1]) === '') {
                continue;
            }
            [$make, $model, $from, $to] = array_map('trim', $parts);
            $years = $from === $to ? $from : $from . "\u{2013}" . $to;
            $vehicles[] = $make . ' ' . $model . ($years !== '' ? ' (' . $years . ')' : '');
        }
        return array_values(array_unique($vehicles));
    }

    /** Marked universal by the POS ("universal" / "U:" lines), or no vehicle listed. */
    public function isUniversal(): bool
    {
        foreach ($this->fitmentLines() as $line) {
            if ($line === 'universal' || str_starts_with($line, 'U:')) {
                return true;
            }
        }
        return $this->getVehicles() === [];
    }

    /** @return string[] */
    private function fitmentLines(): array
    {
        $product = $this->getProduct();
        $text = $product ? (string)$product->getData('cz_fitment') : '';
        return array_values(array_filter(array_map('trim', preg_split('/\R/', $text) ?: [])));
    }

    public function getPhoneUrl(): string
    {
        return 'tel:' . self::PHONE;
    }

    public function getPhoneText(): string
    {
        return self::PHONE_TEXT;
    }

    public function getWhatsappUrl(string $message = ''): string
    {
        return self::WHATSAPP . ($message !== '' ? '?text=' . rawurlencode($message) : '');
    }

    public function getCheckoutUrl(): string
    {
        return $this->getUrl('checkout', ['_secure' => true]);
    }

    private function money(float $amount): string
    {
        $precision = abs($amount - round($amount)) < 0.005 ? 0 : 2;
        return (string)$this->priceCurrency->format($amount, false, $precision);
    }

    public function getIdentities(): array
    {
        $product = $this->getProduct();
        if (!$product) {
            return [];
        }
        $tags = $product->getIdentities();
        $brand = $this->getBrand();
        if ($brand) {
            $tags[] = Category::CACHE_TAG . '_' . (int)$brand->getId();
        }
        return array_values(array_unique($tags));
    }
}
